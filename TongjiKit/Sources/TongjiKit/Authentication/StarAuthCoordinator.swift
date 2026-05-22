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
    private let starSocialAuthURL: URL = {
        var components = URLComponents(string: "https://star.tongji.edu.cn/api/app-api/system/auth/social-auth-url-redirect")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "36"),
            URLQueryItem(name: "redirectUri", value: "https://star.tongji.edu.cn/app/pages/login/social")
        ]
        return components.url!
    }()

    private var renewTask: Task<Bool, Never>?

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(Self.starTokenInterceptorScript())
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
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
            webView.load(URLRequest(url: starMyURL))
            await waitForStarPageSettle()
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
        guard let landing = await waitForStarLanding() else { return nil }
        guard case let .socialCallback(callback) = landing else {
            log("STAR 已进入前端页面，改从页面请求/存储抽取 token")
            if let token = await tryExtractStarTokenFromPage() {
                return token
            }
            return nil
        }

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

    private enum StarLanding {
        case socialCallback(URL)
        case appPage(URL)
    }

    private func waitForStarLanding() async -> StarLanding? {
        var attemptedPasswordFill = false
        for tick in 0..<18 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let url = webView.url,
               url.host?.lowercased() == "star.tongji.edu.cn",
               url.path.lowercased().hasPrefix("/app/pages/login/social") {
                return .socialCallback(url)
            }
            if let url = webView.url,
               url.host?.lowercased() == "star.tongji.edu.cn",
               url.path.lowercased().hasPrefix("/app/") {
                // 部分情况下 STAR 前端会直接落到 /app/，不会暴露 /login/social?code=...
                // 这时页面脚本已经从 documentStart 开始拦截请求，直接进入页面抽取路径。
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return .appPage(url)
            }
            if !attemptedPasswordFill,
               let url = webView.url,
               isOnIAM(url) {
                attemptedPasswordFill = true
                await tryFillIAMLoginFormIfPossible()
            }
            if tick == 4 || tick == 10 || tick == 17 {
                log("等待 STAR social 回跳中，当前 URL=\(webView.url?.absoluteString ?? "nil")")
            }
        }
        log("等待 STAR social 回跳超时，最终 URL=\(webView.url?.absoluteString ?? "nil")")
        return nil
    }

    private func isOnIAM(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "iam.tongji.edu.cn" || host == "ids.tongji.edu.cn"
    }

    private func tryFillIAMLoginFormIfPossible() async {
        guard store.hasAutoLoginCredentials() else {
            log("STAR IAM 停在登录页，但未开启自动登录凭证")
            return
        }
        guard let credentials = await store.loadAutoLoginCredentials(reason: "同步卓越星个人星值") else {
            log("STAR IAM 自动登录凭证解锁失败或被取消")
            return
        }

        for _ in 0..<10 {
            if await fillIAMLoginForm(username: credentials.user, password: credentials.password) {
                log("STAR IAM 已注入密码并提交表单")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("STAR IAM 未找到可见账号密码表单")
    }

    private func fillIAMLoginForm(username: String, password: String) async -> Bool {
        let safeUser = escapeForJSString(username)
        let safePwd = escapeForJSString(password)
        let script = """
        (function() {
            function visible(el) {
                if (!el || el.disabled || el.type === 'hidden') return false;
                var style = window.getComputedStyle(el);
                if (!style || style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                var rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
            }
            function firstVisible(selector) {
                var nodes = Array.prototype.slice.call(document.querySelectorAll(selector));
                return nodes.find(visible) || null;
            }
            function fill(selector, value) {
                var el = firstVisible(selector);
                if (!el) return false;
                el.focus();
                el.value = value;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            }
            var userFilled = fill('input[name="j_username"]', '\(safeUser)') ||
                             fill('input[name="username"]', '\(safeUser)') ||
                             fill('input[id="username"]', '\(safeUser)') ||
                             fill('input[name="loginName"]', '\(safeUser)') ||
                             fill('input[name="account"]', '\(safeUser)') ||
                             fill('input[type="text"]', '\(safeUser)') ||
                             fill('input[type="tel"]', '\(safeUser)');
            var passwordFilled = fill('input[name="j_password"]', '\(safePwd)') ||
                                 fill('input[name="password"]', '\(safePwd)') ||
                                 fill('input[id="password"]', '\(safePwd)') ||
                                 fill('input[type="password"]', '\(safePwd)');
            if (userFilled && passwordFilled) {
                var button = firstVisible('button[type="submit"], input[type="submit"], .submit-btn, .login-btn, button#loginButton');
                if (button) { button.click(); return true; }
                var form = document.querySelector('form');
                if (form) { form.submit(); return true; }
            }
            return false;
        })()
        """
        let raw = try? await webView.evaluateJavaScript(script)
        return JSONUtils.normalizeJavaScriptValue(raw) == "true"
    }

    private func waitForStarPageSettle() async {
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let url = webView.url,
               url.host?.lowercased() == "star.tongji.edu.cn" {
                return
            }
        }
        log("STAR 我的页面未稳定到 star 域，当前 URL=\(webView.url?.absoluteString ?? "nil")")
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw AuthError.loginFlowFailed("STAR social-login HTTP \(status): \(snippet)")
        }
        let payload = try JSONDecoder().decode(StarSocialLoginResponse.self, from: data)
        guard payload.code == 0,
              let token = normalizeStarToken(payload.data?.accessToken) else {
            throw AuthError.loginFlowFailed(payload.msg?.isEmpty == false ? payload.msg! : "STAR accessToken 缺失")
        }
        return token
    }

    private func tryExtractStarTokenFromXHR() async -> String? {
        return await tryExtractStarTokenFromPage()
    }

    private func tryExtractStarTokenFromPage() async -> String? {
        let storageProbes = [
            "localStorage.getItem('token')",
            "localStorage.getItem('access_token')",
            "localStorage.getItem('Authorization')",
            "localStorage.getItem('ACCESS_TOKEN')",
            "localStorage.getItem('starToken')",
            "localStorage.getItem('vuex')",
            "localStorage.getItem('userInfo')",
            "sessionStorage.getItem('token')",
            "sessionStorage.getItem('access_token')",
            "sessionStorage.getItem('Authorization')",
            "sessionStorage.getItem('ACCESS_TOKEN')",
            "sessionStorage.getItem('starToken')",
            "sessionStorage.getItem('vuex')",
            "sessionStorage.getItem('userInfo')"
        ]
        for probe in storageProbes {
            if let raw = try? await webView.evaluateJavaScript(probe),
               let token = normalizeStarToken(fromPossiblyJSON: JSONUtils.normalizeJavaScriptValue(raw)) {
                return token
            }
        }

        _ = try? await webView.evaluateJavaScript(Self.starTokenInterceptorSource)
        log("STAR token 拦截器已确认，当前 URL=\(webView.url?.absoluteString ?? "nil")")

        // 主动触发 SPA 请求
        let triggers = [
            "fetch('/api/app-api/activity/statistics/start-count', { headers: { platform: 'h5' } }).catch(function(){})",
            "fetch('/api/app-api/user/profile/get', { headers: { platform: 'h5' } }).catch(function(){})",
            "if (typeof uni !== 'undefined' && uni.request) uni.request({ url: '/api/app-api/activity/statistics/start-count', method: 'GET', header: { platform: 'h5' } })"
        ]
        for script in triggers {
            _ = try? await webView.evaluateJavaScript(script)
        }

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let raw = try? await webView.evaluateJavaScript("window.__starToken || ''"),
               let token = normalizeStarToken(fromPossiblyJSON: JSONUtils.normalizeJavaScriptValue(raw)) {
                return token
            }
            if let raw = try? await webView.evaluateJavaScript(Self.starTokenDumpScript),
               let token = normalizeStarToken(fromPossiblyJSON: JSONUtils.normalizeJavaScriptValue(raw)) {
                return token
            }
        }
        return nil
    }

    private static func starTokenInterceptorScript() -> WKUserScript {
        WKUserScript(
            source: starTokenInterceptorSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let starTokenInterceptorSource = """
    (function() {
        if (window.__starInstrumented) return;
        window.__starInstrumented = true;
        window.__starToken = window.__starToken || '';
        function remember(value) {
            try {
                if (!value) return;
                var text = String(value);
                if (/^Bearer\\s+/i.test(text)) text = text.replace(/^Bearer\\s+/i, '');
                if (text.length >= 20 && text !== 'undefined' && text !== 'null') {
                    window.__starToken = text;
                }
            } catch (e) {}
        }
        function inspectHeaders(headers) {
            try {
                if (!headers) return;
                if (typeof Headers !== 'undefined' && headers instanceof Headers) {
                    remember(headers.get('authorization') || headers.get('Authorization'));
                    return;
                }
                if (Array.isArray(headers)) {
                    headers.forEach(function(pair) {
                        if (pair && String(pair[0]).toLowerCase() === 'authorization') remember(pair[1]);
                    });
                    return;
                }
                Object.keys(headers).forEach(function(key) {
                    if (String(key).toLowerCase() === 'authorization') remember(headers[key]);
                });
            } catch (e) {}
        }
        try {
            var origSet = XMLHttpRequest.prototype.setRequestHeader;
            XMLHttpRequest.prototype.setRequestHeader = function(k, v) {
                if (k && String(k).toLowerCase() === 'authorization') remember(v);
                return origSet.apply(this, arguments);
            };
        } catch (e) {}
        try {
            var origFetch = window.fetch;
            window.fetch = function(input, init) {
                try {
                    if (init && init.headers) inspectHeaders(init.headers);
                    if (input && input.headers) inspectHeaders(input.headers);
                } catch (e) {}
                return origFetch.apply(this, arguments);
            };
        } catch (e) {}
    })();
    """

    private static let starTokenDumpScript = """
    (function() {
        var found = [];
        function add(v) {
            try {
                if (v === null || v === undefined) return;
                found.push(String(v));
            } catch (e) {}
        }
        add(window.__starToken || '');
        [localStorage, sessionStorage].forEach(function(storage) {
            try {
                for (var i = 0; i < storage.length; i++) {
                    var key = storage.key(i);
                    add(storage.getItem(key));
                }
            } catch (e) {}
        });
        return found.join('\\n');
    })()
    """

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

    private func normalizeStarToken(fromPossiblyJSON value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let token = normalizeStarToken(value) {
            return token
        }

        let patterns = [
            #""accessToken"\s*:\s*"([^"]+)""#,
            #""access_token"\s*:\s*"([^"]+)""#,
            #""token"\s*:\s*"([^"]+)""#,
            #""Authorization"\s*:\s*"([^"]+)""#,
            #""authorization"\s*:\s*"([^"]+)""#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
            let matches = regex.matches(in: value, range: nsRange)
            for match in matches where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: value) else { continue }
                if let token = normalizeStarToken(String(value[range])) {
                    return token
                }
            }
        }
        return nil
    }

    private func escapeForJSString(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "'", with: "\\'")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        return out
    }

    private func log(_ message: String) {
        let line = "[StarAuth] \(message)"
        print(line)
        logger.info("\(line, privacy: .public)")
    }
}

extension StarAuthCoordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("didFinish → \(webView.url?.absoluteString ?? "nil")")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("didFail → \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("didFailProvisional → \(error.localizedDescription)")
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
