import Foundation
@preconcurrency import WebKit
import os.log

/// 校园卡（一卡通）鉴权协调器。
///
/// 目标是尽量复用统一身份登录后的 SSO 状态，在隐藏 WebView 中访问
/// `pay-yikatong.tongji.edu.cn`，并提取：
/// - `JWTUser` / `TGC` Cookie
/// - URL 中的 `synjones-auth` Bearer Token
///
/// 这条链路参考 wish_drom 的抓取策略，但在 iOS 端做成静默续期，不打断主界面。
@MainActor
public final class YikatongAuthCoordinator: NSObject, ObservableObject {
    public static let shared = YikatongAuthCoordinator()

    public let webView: WKWebView
    private let store: CredentialStore
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "YikatongAuth")

    private let entryURL = URL(
        string: "https://pay-yikatong.tongji.edu.cn/berserker-auth/cas/redirect/bamboocloud?targetUrl=https://pay-yikatong.tongji.edu.cn/plat/?name=loginTransit"
    )!
    private let walletURL = URL(string: "https://pay-yikatong.tongji.edu.cn/plat/wode")!
    private var renewTask: Task<Bool, Never>?

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    public func renewIfPossible() async -> Bool {
        if let renewTask { return await renewTask.value }
        let task = Task<Bool, Never> { @MainActor in
            log("启动校园卡续期：访问登录中转页")
            webView.load(URLRequest(url: entryURL))

            var attemptedPasswordFill = false
            for tick in 0..<18 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                if await tryStoreCredentialsFromCurrentPage() {
                    log("校园卡 Token 与 Cookie 已就绪")
                    return true
                }

                if !attemptedPasswordFill,
                   let url = webView.url,
                   isOnIAM(url) {
                    attemptedPasswordFill = true
                    await tryFillIAMLoginFormIfPossible()
                } else if let url = webView.url,
                          url.host?.contains("pay-yikatong.tongji.edu.cn") == true,
                          tick == 8 {
                    log("校园卡仍未拿到 Token，尝试主动访问钱包页")
                    webView.load(URLRequest(url: walletURL))
                }

                if tick == 4 || tick == 10 || tick == 17 {
                    log("等待校园卡回跳中，当前 URL=\(webView.url?.absoluteString ?? "nil")")
                }
            }

            log("校园卡续期失败")
            return false
        }
        renewTask = task
        let result = await task.value
        renewTask = nil
        return result
    }

    private func tryStoreCredentialsFromCurrentPage() async -> Bool {
        let currentURLString = webView.url?.absoluteString ?? ""
        let extractedToken = extractToken(from: currentURLString)
        let storedToken: String?
        if let extractedToken {
            storedToken = extractedToken
        } else {
            storedToken = await readStoredBearerToken()
        }
        if let token = storedToken {
            store.set(token, for: CredentialStore.Keys.yikatongBearerToken)
            log("已提取校园卡 Token，长度=\(token.count)")
        }

        let cookieHeader = await yikatongCookieHeader()
        if !cookieHeader.isEmpty {
            store.set(cookieHeader, for: CredentialStore.Keys.yikatongCookies)
            log("已提取校园卡 Cookie，长度=\(cookieHeader.count)")
        } else if let fallbackCookie = await readDocumentCookieHeader(), !fallbackCookie.isEmpty {
            store.set(fallbackCookie, for: CredentialStore.Keys.yikatongCookies)
            log("已从 document.cookie 提取校园卡 Cookie，长度=\(fallbackCookie.count)")
        }

        let hasToken = store.get(CredentialStore.Keys.yikatongBearerToken)?.isEmpty == false
        let hasCookie = store.get(CredentialStore.Keys.yikatongCookies)?.isEmpty == false
        log("当前凭证状态：token=\(hasToken) cookie=\(hasCookie) url=\(currentURLString)")
        return hasToken && hasCookie
    }

    private func yikatongCookieHeader() async -> String {
        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        let values = cookies
            .filter { cookie in
                let host = cookie.domain.lowercased()
                return host.contains("pay-yikatong.tongji.edu.cn")
                    && (cookie.name == "JWTUser" || cookie.name == "TGC")
            }
            .map { "\($0.name)=\($0.value)" }

        return values.joined(separator: "; ")
    }

    private func readDocumentCookieHeader() async -> String? {
        let raw = try? await webView.evaluateJavaScript("document.cookie")
        guard let cookie = JSONUtils.normalizeJavaScriptValue(raw), !cookie.isEmpty else {
            return nil
        }
        let values = cookie
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("JWTUser=") || $0.hasPrefix("TGC=") }
        return values.isEmpty ? nil : values.joined(separator: "; ")
    }

    private func readStoredBearerToken() async -> String? {
        let script = """
        (function() {
            const candidates = [
                sessionStorage.getItem('access_token'),
                localStorage.getItem('access_token'),
                sessionStorage.getItem('token'),
                localStorage.getItem('token')
            ].filter(Boolean);
            return candidates.length ? candidates[0] : '';
        })()
        """
        let raw = try? await webView.evaluateJavaScript(script)
        guard let token = JSONUtils.normalizeJavaScriptValue(raw)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func extractToken(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let raw = components.queryItems?.first(where: { $0.name == "synjones-auth" })?.value,
              !raw.isEmpty else {
            return nil
        }
        if raw.lowercased().hasPrefix("bearer ") {
            return String(raw.dropFirst(7))
        }
        return raw
    }

    private func isOnIAM(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "iam.tongji.edu.cn" || host == "ids.tongji.edu.cn"
    }

    private func tryFillIAMLoginFormIfPossible() async {
        guard store.hasAutoLoginCredentials() else {
            log("校园卡 IAM 停在登录页，但未开启自动登录凭证")
            return
        }
        guard let credentials = await store.loadAutoLoginCredentials(reason: "同步校园卡余额") else {
            log("校园卡 IAM 自动登录凭证解锁失败或被取消")
            return
        }

        for _ in 0..<10 {
            if await fillIAMLoginForm(username: credentials.user, password: credentials.password) {
                log("校园卡 IAM 已注入密码并提交表单")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("校园卡 IAM 未找到可见账号密码表单")
    }

    private func fillIAMLoginForm(username: String, password: String) async -> Bool {
        let safeUser = escapeForJSString(username)
        let safePwd = escapeForJSString(password)
        let script = """
        (function() {
            function visible(el) {
                if (!el || el.disabled || el.type === 'hidden') return false;
                const style = window.getComputedStyle(el);
                if (!style || style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
            }
            function firstVisible(selector) {
                const nodes = Array.prototype.slice.call(document.querySelectorAll(selector));
                return nodes.find(visible) || null;
            }
            function fill(selector, value) {
                const el = firstVisible(selector);
                if (!el) return false;
                el.focus();
                el.value = value;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            }
            const userFilled = fill('input[name="j_username"]', '\(safeUser)') ||
                               fill('input[name="username"]', '\(safeUser)') ||
                               fill('input[id="username"]', '\(safeUser)') ||
                               fill('input[name="loginName"]', '\(safeUser)') ||
                               fill('input[name="account"]', '\(safeUser)') ||
                               fill('input[type="text"]', '\(safeUser)') ||
                               fill('input[type="tel"]', '\(safeUser)');
            const passwordFilled = fill('input[name="j_password"]', '\(safePwd)') ||
                                   fill('input[name="password"]', '\(safePwd)') ||
                                   fill('input[id="password"]', '\(safePwd)') ||
                                   fill('input[type="password"]', '\(safePwd)');
            if (userFilled && passwordFilled) {
                const button = firstVisible('button[type="submit"], input[type="submit"], .submit-btn, .login-btn, button#loginButton');
                if (button) { button.click(); return true; }
                const form = document.querySelector('form');
                if (form) { form.submit(); return true; }
            }
            return false;
        })()
        """
        let raw = try? await webView.evaluateJavaScript(script)
        return JSONUtils.normalizeJavaScriptValue(raw) == "true"
    }

    private func escapeForJSString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        print("[YikatongAuth] \(message)")
    }
}

extension YikatongAuthCoordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("didFinish → \(webView.url?.absoluteString ?? "nil")")
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        log("didFailProvisional → \(error.localizedDescription)")
    }
}
