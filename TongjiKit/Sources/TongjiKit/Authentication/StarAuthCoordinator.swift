import Foundation
@preconcurrency import WebKit
import os.log

/// 卓越星 STAR 平台鉴权协调器（独立于一系统）。
///
/// 责任：抽取 / 续期 STAR Bearer Token，**不影响** `CampusModel.authState`。
///
/// 主路径：访问 `social-auth-url-redirect?type=36` → IAM SSO 回跳带 code/state
/// → 调 `/api/app-api/system/auth/social-login` 换 accessToken。
/// 兜底路径：在隐藏 webview 里运行 XHR `setRequestHeader` 拦截脚本，
/// 从前端请求里抓 `Authorization`。
///
/// **Single-flight**：同一时刻只跑一次续期，多次调用共享同一个 Task。
@MainActor
public final class StarAuthCoordinator: NSObject, ObservableObject {

    public static let shared = StarAuthCoordinator()

    public let webView: WKWebView
    private let store: CredentialStore
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "StarAuth")

    private let starMyURL = URL(string: "https://star.tongji.edu.cn/app/pages/index/my")!
    private let starSocialAuthURL = URL(string: "https://star.tongji.edu.cn/api/app-api/system/auth/social-auth-url-redirect?type=36&redirectUri=https://star.tongji.edu.cn/app/pages/login/social")!

    private var renewTask: Task<Bool, Never>?

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
    }

    public func renewIfPossible() async -> Bool {
        if let task = renewTask { return await task.value }
        let task = Task<Bool, Never> { @MainActor in
            // 清掉旧 token，避免兜底脚本误判
            store.remove(CredentialStore.Keys.starBearerToken)

            log("启动 STAR 续期：访问 social-auth-url-redirect")
            webView.load(URLRequest(url: starSocialAuthURL))

            if let token = await tryExchangeStarSocialToken() {
                store.set(token, for: CredentialStore.Keys.starBearerToken)
                log("STAR accessToken 已存储 (len=\(token.count))")
                return true
            }

            // 兜底：XHR 拦截
            log("正路失败，尝试 XHR 拦截兜底")
            if let token = await tryExtractStarTokenFromXHR() {
                store.set(token, for: CredentialStore.Keys.starBearerToken)
                log("XHR 兜底拿到 token (len=\(token.count))")
                return true
            }

            log("STAR 续期失败")
            return false
        }
        renewTask = task
        let result = await task.value
        renewTask = nil
        return result
    }

    private func tryExchangeStarSocialToken() async -> String? {
        guard let callback = await waitForStarSocialCallback() else { return nil }
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components?.queryItems?.first(where: { $0.name == "state" })?.value,
              !code.isEmpty, !state.isEmpty else {
            log("回跳缺 code/state")
            return nil
        }

        do {
            let token = try await requestStarAccessToken(code: code, state: state)
            webView.load(URLRequest(url: starMyURL))
            return token
        } catch {
            log("social-login 换 token 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func waitForStarSocialCallback() async -> URL? {
        for _ in 0..<18 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let url = webView.url,
               url.host?.lowercased() == "star.tongji.edu.cn",
               url.path.lowercased().hasPrefix("/app/pages/login/social") {
                return url
            }
        }
        return nil
    }

    private func requestStarAccessToken(code: String, state: String) async throws -> String {
        let url = URL(string: "https://star.tongji.edu.cn/api/app-api/system/auth/social-login?")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("h5", forHTTPHeaderField: "platform")
        request.setValue("https://star.tongji.edu.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://star.tongji.edu.cn", forHTTPHeaderField: "X-Request-Origin")
        request.setValue(
            "https://star.tongji.edu.cn/app/pages/login/social?code=\(code)&state=\(state)&type=36",
            forHTTPHeaderField: "Referer"
        )
        let body: [String: String] = ["type": "36", "code": code, "state": state]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.loginFlowFailed("STAR social-login HTTP 异常")
        }
        let payload = try JSONDecoder().decode(StarSocialLoginResponse.self, from: data)
        guard payload.code == 0,
              let token = normalizeStarToken(payload.data?.accessToken) else {
            throw AuthError.loginFlowFailed(payload.msg?.isEmpty == false ? payload.msg! : "STAR accessToken 缺失")
        }
        return token
    }

    private func tryExtractStarTokenFromXHR() async -> String? {
        let storageProbes = [
            "localStorage.getItem('token')",
            "localStorage.getItem('access_token')",
            "localStorage.getItem('Authorization')",
            "sessionStorage.getItem('token')",
            "sessionStorage.getItem('access_token')",
            "sessionStorage.getItem('Authorization')"
        ]
        for probe in storageProbes {
            if let raw = try? await webView.evaluateJavaScript(probe),
               let token = normalizeStarToken(JSONUtils.normalizeJavaScriptValue(raw)) {
                return token
            }
        }

        let installInterceptor = """
        (function() {
            if (window.__starInstrumented) return;
            window.__starInstrumented = true;
            window.__starToken = '';
            var origSet = XMLHttpRequest.prototype.setRequestHeader;
            XMLHttpRequest.prototype.setRequestHeader = function(k, v) {
                try {
                    if (k && k.toLowerCase() === 'authorization' && v) window.__starToken = v;
                } catch (e) {}
                return origSet.apply(this, arguments);
            };
        })();
        """
        _ = try? await webView.evaluateJavaScript(installInterceptor)

        // 主动触发 SPA 请求
        let triggers = [
            "fetch('/api/app-api/activity/statistics/start-count', { headers: { platform: 'h5' } }).catch(function(){})",
            "if (typeof uni !== 'undefined' && uni.request) uni.request({ url: '/api/app-api/activity/statistics/start-count', method: 'GET', header: { platform: 'h5' } })"
        ]
        for script in triggers {
            _ = try? await webView.evaluateJavaScript(script)
        }

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let raw = try? await webView.evaluateJavaScript("window.__starToken || ''"),
               let token = normalizeStarToken(JSONUtils.normalizeJavaScriptValue(raw)) {
                return token
            }
        }
        return nil
    }

    private func normalizeStarToken(_ value: String?) -> String? {
        guard var token = value?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        if token.lowercased().hasPrefix("bearer ") {
            token.removeFirst(7)
        }
        let lowercased = token.lowercased()
        guard token.count >= 20,
              lowercased != "bearer",
              lowercased != "null",
              lowercased != "undefined" else {
            return nil
        }
        return token
    }

    private func log(_ message: String) {
        let line = "[StarAuth] \(message)"
        print(line)
        logger.info("\(line, privacy: .public)")
    }
}

private struct StarSocialLoginResponse: Decodable {
    let code: Int
    let data: StarSocialLoginData?
    let msg: String?
}

private struct StarSocialLoginData: Decodable {
    let accessToken: String?
}
