import Foundation
@preconcurrency import WebKit
import os.log

/// 校园卡（一卡通）鉴权协调器。
///
/// 目标是尽量复用统一身份登录后的 SSO 状态，在隐藏 WebView 中访问
/// `pay-yikatong.tongji.edu.cn`，并提取：
/// - `JWTUser` / `TGC` Cookie
/// - URL 中的 `synjones-auth` Bearer Token
/// - `loginTransit` 里的 ticket 换取出的 `access_token`
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
    private let portalURL = URL(string: "https://all4u.tongji.edu.cn/tj-portal/page/mobile/index")!
    private let walletURL = URL(string: "https://pay-yikatong.tongji.edu.cn/plat/wode")!
    private let tokenURL = URL(string: "https://pay-yikatong.tongji.edu.cn/berserker-auth/oauth/token")!
    private var renewTask: Task<Bool, Never>?
    private var bridgeMessagesLogged = Set<String>()

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController = userContentController
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        userContentController.add(self, name: "SynJSNative")
        userContentController.add(self, name: "YikatongCredentialProbe")
        self.webView.navigationDelegate = self
        log("已注入校园卡 SynJSNative 兼容桥")
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
                          tick == 6 {
                    log("校园卡仍未拿到 Token，尝试主动访问 H5 loginTransit")
                    webView.load(URLRequest(url: URL(string: "https://pay-yikatong.tongji.edu.cn/plat/?name=loginTransit")!))
                } else if let url = webView.url,
                          url.host?.contains("pay-yikatong.tongji.edu.cn") == true,
                          tick == 10 {
                    log("校园卡仍未拿到 Token，尝试主动访问钱包页")
                    webView.load(URLRequest(url: walletURL))
                } else if tick == 14 {
                    log("校园卡仍未拿到 Token，尝试 all4u 入口兜底")
                    webView.load(URLRequest(url: portalURL))
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
        } else if let ticket = extractTicket(from: currentURLString),
                  let token = await exchangeTicketForToken(ticket) {
            storedToken = token
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
        return hasToken
    }

    private func yikatongCookieHeader() async -> String {
        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        let yikatongCookies = cookies.filter { cookie in
            cookie.domain.lowercased().contains("pay-yikatong.tongji.edu.cn")
        }
        if !yikatongCookies.isEmpty {
            log("校园卡 Cookie 名称：\(yikatongCookies.map(\.name).sorted().joined(separator: ","))")
        }

        let values = yikatongCookies
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
        return values.isEmpty ? nil : values.joined(separator: "; ")
    }

    private func readStoredBearerToken() async -> String? {
        guard webView.url?.host?.lowercased().contains("pay-yikatong.tongji.edu.cn") == true else {
            return nil
        }
        let script = """
        (function() {
            function values(storage) {
                const out = [];
                if (!storage) return out;
                for (let i = 0; i < storage.length; i++) {
                    const key = storage.key(i);
                    const value = storage.getItem(key);
                    if (value) out.push({ key, value });
                }
                return out;
            }
            const candidates = [
                window.__jinitaimei_yikatong_token,
                sessionStorage.getItem('access_token'),
                localStorage.getItem('access_token')
            ].filter(Boolean);
            for (const item of values(sessionStorage).concat(values(localStorage))) {
                const key = String(item.key || '').toLowerCase();
                const value = String(item.value || '');
                if (key === 'access_token' || value.includes('synjones-auth') || value.includes('"access_token"')) {
                    candidates.push(value);
                }
            }
            return candidates.length ? candidates[0] : '';
        })()
        """
        let raw = try? await webView.evaluateJavaScript(script)
        guard let token = JSONUtils.normalizeJavaScriptValue(raw)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return normalizeBearerToken(token)
    }

    private func extractToken(from urlString: String) -> String? {
        if let direct = extractTokenValue(from: urlString) {
            return direct
        }
        if let decoded = urlString.removingPercentEncoding, decoded != urlString {
            return extractTokenValue(from: decoded)
        }
        return nil
    }

    private func extractTokenValue(from urlString: String) -> String? {
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

    private func normalizeBearerToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = payload["access_token"] as? String,
           !token.isEmpty {
            return token
        }
        if let match = trimmed.range(
            of: #""access_token"\s*:\s*"([^"]+)""#,
            options: .regularExpression
        ) {
            let segment = String(trimmed[match])
            let parts = segment.components(separatedBy: "\"")
            if let token = parts.dropLast().last, !token.isEmpty {
                return token
            }
        }
        if trimmed.lowercased().hasPrefix("bearer ") {
            return String(trimmed.dropFirst(7))
        }
        return trimmed.count >= 32 ? trimmed : nil
    }

    private func extractTicket(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let raw = components.queryItems?.first(where: { $0.name == "ticket" })?.value,
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func exchangeTicketForToken(_ ticket: String) async -> String? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Basic bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm06bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm1fc2VjcmV0",
            forHTTPHeaderField: "Authorization"
        )
        let fields: [String: String] = [
            "username": ticket,
            "password": ticket,
            "grant_type": "password",
            "scope": "all",
            "loginFrom": "app",
            "logintype": "sso",
            "device_token": "h5"
        ]
        request.httpBody = fields
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                log("校园卡 ticket 换 token 响应：HTTP \(http.statusCode)")
                if let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") {
                    let cookieHeader = parseSetCookieHeader(setCookie)
                    if !cookieHeader.isEmpty {
                        store.set(cookieHeader, for: CredentialStore.Keys.yikatongCookies)
                        log("已从 ticket 响应提取校园卡 Cookie，名称=\(cookieHeader.cookieNamesForLog)")
                    }
                }
                guard (200..<300).contains(http.statusCode) else {
                    log("校园卡 ticket 换 token 非成功响应：\(tokenErrorSummary(from: data))")
                    return nil
                }
            }
            let payload = try JSONDecoder().decode(YikatongOAuthTokenResponse.self, from: data)
            guard !payload.accessToken.isEmpty else { return nil }
            log("已通过 loginTransit ticket 换取校园卡 Token，长度=\(payload.accessToken.count)")
            return payload.accessToken
        } catch {
            log("校园卡 ticket 换 token 失败：\(error.localizedDescription)")
            return nil
        }
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

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "%+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func parseSetCookieHeader(_ raw: String) -> String {
        raw
            .components(separatedBy: ",")
            .compactMap { item in
                item.split(separator: ";", maxSplits: 1).first
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("=") }
            .joined(separator: "; ")
    }

    private func tokenErrorSummary(from data: Data) -> String {
        guard !data.isEmpty else { return "empty-body" }
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = ["code", "error", "message", "msg", "error_description"]
            let summary = keys
                .compactMap { key -> String? in
                    guard let value = payload[key] else { return nil }
                    return "\(key)=\(value)"
                }
                .joined(separator: ",")
            if !summary.isEmpty { return summary }
        }
        let text = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(text.prefix(120))
    }

    private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        print("[YikatongAuth] \(message)")
    }

    private static let bridgeScript = """
    (function() {
        if (window.__jinitaimeiYikatongBridgeInstalled) return;
        window.__jinitaimeiYikatongBridgeInstalled = true;
        window.__jinitaimei_yikatong_native_store = window.__jinitaimei_yikatong_native_store || {};

        function post(kind, payload) {
            try {
                window.webkit.messageHandlers.YikatongCredentialProbe.postMessage({
                    kind: kind,
                    payload: payload || null,
                    href: window.location.href
                });
            } catch (e) {}
        }

        function rememberToken(raw, source) {
            if (!raw) return;
            var value = String(raw);
            var match = value.match(/synjones-auth=([^&"'\\s]+)/);
            if (match) value = decodeURIComponent(match[1]);
            if (!match) {
                var accessToken = value.match(/"access_token"\\s*:\\s*"([^"]+)"/);
                if (accessToken) value = accessToken[1];
            }
            if (value.toLowerCase().indexOf('bearer ') === 0) value = value.slice(7);
            if (value.length >= 32) {
                window.__jinitaimei_yikatong_token = value;
                post('token', { source: source, length: value.length });
            }
        }

        function inspect(value, source) {
            if (value === undefined || value === null) return;
            var text = typeof value === 'string' ? value : JSON.stringify(value);
            if (text.indexOf('synjones-auth') >= 0 || text.indexOf('access_token') >= 0) {
                rememberToken(text, source);
            }
        }

        var originalSetItem = Storage.prototype.setItem;
        Storage.prototype.setItem = function(key, value) {
            inspect(String(key) + '=' + String(value), 'storage');
            return originalSetItem.apply(this, arguments);
        };

        var originalOpen = XMLHttpRequest.prototype.open;
        var originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
        var originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
            this.__jinitaimeiUrl = url;
            inspect(url, 'xhr-open');
            return originalOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            if (String(name).toLowerCase() === 'synjones-auth') rememberToken(value, 'xhr-header');
            return originalSetRequestHeader.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
            this.addEventListener('load', function() {
                inspect(this.responseText, 'xhr-response');
            });
            return originalSend.apply(this, arguments);
        };

        var originalFetch = window.fetch;
        if (originalFetch) {
            window.fetch = function(input, init) {
                inspect(input && input.url ? input.url : input, 'fetch-url');
                if (init && init.headers) inspect(init.headers, 'fetch-header');
                return originalFetch.apply(this, arguments).then(function(response) {
                    try {
                        response.clone().text().then(function(text) { inspect(text, 'fetch-response'); });
                    } catch (e) {}
                    return response;
                });
            };
        }

        function handleNativeMessage(message) {
            var raw = typeof message === 'string' ? message : JSON.stringify(message || {});
            inspect(raw, 'native-message');
            var payload = {};
            try { payload = typeof message === 'string' ? JSON.parse(message) : (message || {}); } catch (e) {}
            var key = payload.primaryKey || '';
            post('bridge', { key: key, objKey: payload.objKey || null });
            if (key === 'synjones.ecampus.tool.setObject' && payload.objKey) {
                var value = payload.info !== undefined ? payload.info : payload.objValue;
                window.__jinitaimei_yikatong_native_store[payload.objKey] = value || '';
                inspect(String(payload.objKey) + '=' + String(value || ''), 'native-setObject');
            }
            if (key === 'synjones.ecampus.tool.getObject' && payload.objKey && payload.callback) {
                var stored = window.__jinitaimei_yikatong_native_store[payload.objKey] || '';
                try {
                    var callback = payload.callback.split('.').reduce(function(obj, part) { return obj && obj[part]; }, window);
                    if (typeof callback === 'function') callback(stored);
                } catch (e) {}
            }
            var target = (payload.param && payload.param.url) || payload.url || payload.loadURL || '';
            if (target) {
                inspect(target, 'native-url');
                if (/^https?:/.test(target) && (target.indexOf('pay-yikatong.tongji.edu.cn') >= 0 || target.indexOf('synjones-auth') >= 0)) {
                    window.location.href = target;
                }
            }
            return '';
        }

        window.AndroidFunc = window.AndroidFunc || {};
        window.AndroidFunc.SynJSNative = handleNativeMessage;
        post('installed', { ua: navigator.userAgent });
    })();
    """
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

extension YikatongAuthCoordinator: WKScriptMessageHandler {
    nonisolated public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            handleScriptMessage(message)
        }
    }

    private func handleScriptMessage(_ message: WKScriptMessage) {
        if message.name == "YikatongCredentialProbe" {
            guard let body = message.body as? [String: Any] else { return }
            let kind = body["kind"] as? String ?? "unknown"
            if kind == "token",
               let payload = body["payload"] as? [String: Any],
               let source = payload["source"] as? String,
               let length = payload["length"] {
                log("JS 捕获校园卡 Token 线索：source=\(source) length=\(length)")
            } else if kind == "bridge",
                      let payload = body["payload"] as? [String: Any],
                      let key = payload["key"] as? String,
                      !bridgeMessagesLogged.contains(key) {
                bridgeMessagesLogged.insert(key)
                log("SynJSNative 调用：\(key)")
            } else if kind == "installed" {
                log("校园卡 JS 拦截器已安装")
            }
            return
        }

        if message.name == "SynJSNative" {
            let raw = String(describing: message.body)
            if let token = extractToken(from: raw) {
                store.set(token, for: CredentialStore.Keys.yikatongBearerToken)
                log("从 SynJSNative 消息提取校园卡 Token，长度=\(token.count)")
            }
        }
    }
}

private struct YikatongOAuthTokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private extension String {
    var cookieNamesForLog: String {
        split(separator: ";")
            .compactMap { item in
                item.split(separator: "=", maxSplits: 1).first
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }
}
