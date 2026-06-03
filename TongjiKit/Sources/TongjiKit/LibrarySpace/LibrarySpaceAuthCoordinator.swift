import Foundation
import os
import WebKit

@MainActor
public final class LibrarySpaceAuthCoordinator: NSObject, ObservableObject {
    public static let shared = LibrarySpaceAuthCoordinator()

    public struct WebFetchResult: Sendable {
        public let statusCode: Int
        public let data: Data
    }

    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "LibrarySpaceAuth")
    private let store: CredentialStore
    private let session: URLSession
    private var renewTask: Task<Bool, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var webView: WKWebView?
    private var attemptedPasswordFill = false

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
        super.init()
    }

    public func renewIfPossible() async -> Bool {
        if let renewTask {
            log("已有图书馆续期任务在跑，复用结果")
            return await renewTask.value
        }

        let task = Task { @MainActor in
            defer { renewTask = nil }
            return await runWebRenew()
        }
        renewTask = task
        return await task.value
    }

    public func clearToken() {
        store.remove(CredentialStore.Keys.librarySpaceBearerToken)
    }

    public func postFromAuthenticatedWebView(path: String, bodyData: Data) async throws -> WebFetchResult {
        guard let webView else {
            throw AuthError.loginFlowFailed("图书馆 WebView 会话不可用")
        }
        guard webView.url?.host?.lowercased() == "space.tongji.edu.cn" else {
            throw AuthError.loginFlowFailed("图书馆 WebView 尚未进入 space 域")
        }
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw AuthError.loginFlowFailed("图书馆请求体编码失败")
        }
        let authorization = authorizationValue(from: bodyData) ?? ""

        let script = """
        const response = await fetch(path, {
            method: 'POST',
            headers: {
                'Accept': 'application/json, text/plain, */*',
                'Content-Type': 'application/json',
                'X-Requested-With': 'XMLHttpRequest',
                'lang': 'zh',
                'authorization': authorization
            },
            body: body
        });
        const text = await response.text();
        return JSON.stringify({ status: response.status, text: text });
        """
        let raw = try await webView.callAsyncJavaScript(
            script,
            arguments: [
                "path": path,
                "body": body,
                "authorization": authorization
            ],
            in: nil,
            contentWorld: .page
        )
        let normalized = JSONUtils.normalizeJavaScriptValue(raw) ?? ""
        guard let data = normalized.data(using: .utf8) else {
            throw AuthError.loginFlowFailed("图书馆 WebView 响应编码失败")
        }
        let payload = try JSONDecoder().decode(WebFetchEnvelope.self, from: data)
        guard let responseData = payload.text.data(using: .utf8) else {
            throw AuthError.loginFlowFailed("图书馆 WebView 响应正文编码失败")
        }
        return WebFetchResult(statusCode: payload.status, data: responseData)
    }

    private func authorizationValue(from bodyData: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let authorization = object["authorization"] as? String,
              !authorization.isEmpty else {
            return nil
        }
        return authorization
    }

    private func runWebRenew() async -> Bool {
        log("启动图书馆空间系统续期")
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.attemptedPasswordFill = false

            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            self.webView = webView

            let state = UUID().uuidString
            let redirect = "https://space.tongji.edu.cn/api/Oauth3/login"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = URL(string:
                "https://iam.tongji.edu.cn/idp/oauth2/authorize?response_type=code&redirect_uri=\(redirect)&state=\(state)&client_id=SYS20230204"
            )!
            webView.load(URLRequest(url: url))

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if self.continuation != nil {
                    self.log("图书馆续期超时")
                    self.finish(false)
                }
            }
        }
    }

    private func exchangeCas(_ cas: String) async {
        do {
            let token = try await exchangeCasForToken(cas)
            store.set(token, for: CredentialStore.Keys.librarySpaceBearerToken)
            let savedLength = store.get(CredentialStore.Keys.librarySpaceBearerToken)?.count ?? 0
            guard savedLength > 0 else {
                throw AuthError.loginFlowFailed("图书馆 JWT 写入后读取失败")
            }
            await installAuthenticatedState(token: token)
            log("图书馆 JWT 已存储，长度=\(token.count)，读回长度=\(savedLength)")
            finish(true)
        } catch {
            log("图书馆 cas 换 JWT 失败：\(error.localizedDescription)")
            finish(false)
        }
    }

    private func installAuthenticatedState(token: String) async {
        guard let webView else { return }
        let script = """
        sessionStorage.setItem('token', token);
        localStorage.setItem('lang', localStorage.getItem('lang') || 'zh');
        """
        do {
            _ = try await webView.callAsyncJavaScript(
                script,
                arguments: ["token": token],
                in: nil,
                contentWorld: .page
            )
            log("图书馆 H5 登录态已写入 sessionStorage")
        } catch {
            log("图书馆 H5 登录态写入失败：\(error.localizedDescription)")
        }
    }

    private func exchangeCasForToken(_ cas: String) async throws -> String {
        let url = URL(string: "https://space.tongji.edu.cn/api/cas/user")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://space.tongji.edu.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://space.tongji.edu.cn/h5/", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONEncoder().encode(CasUserRequest(cas: cas))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.loginFlowFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let payload = try JSONDecoder().decode(CasUserResponse.self, from: data)
        guard payload.code == 1, let token = payload.member?.token, !token.isEmpty else {
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "图书馆登录响应异常" : payload.msg)
        }
        return token
    }

    private func finish(_ ok: Bool) {
        let continuation = continuation
        self.continuation = nil
        attemptedPasswordFill = false
        if !ok {
            webView?.navigationDelegate = nil
            webView?.stopLoading()
            webView = nil
        }
        continuation?.resume(returning: ok)
    }

    private func log(_ message: String) {
        let line = "[LibrarySpaceAuth] \(message)"
        logger.info("\(line, privacy: .public)")
        print(line)
    }

    private func isOnIAM(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "iam.tongji.edu.cn" || host == "ids.tongji.edu.cn"
    }

    private func tryFillIAMLoginFormIfPossible() async {
        guard continuation != nil else { return }
        guard store.hasAutoLoginCredentials() else {
            log("图书馆 IAM 停在登录页，但未开启自动登录凭证")
            finish(false)
            return
        }
        guard let credentials = await store.loadAutoLoginCredentials(reason: "同步图书馆座位状态") else {
            log("图书馆 IAM 自动登录凭证解锁失败或被取消")
            finish(false)
            return
        }

        for _ in 0..<16 {
            guard continuation != nil else { return }
            if await fillIAMLoginForm(username: credentials.user, password: credentials.password) {
                log("图书馆 IAM 已注入密码并提交表单")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("图书馆 IAM 未找到可见账号密码表单")
    }

    private func fillIAMLoginForm(username: String, password: String) async -> Bool {
        guard let webView else { return false }
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

    private func escapeForJSString(_ value: String) -> String {
        var output = value.replacingOccurrences(of: "\\", with: "\\\\")
        output = output.replacingOccurrences(of: "'", with: "\\'")
        output = output.replacingOccurrences(of: "\n", with: "\\n")
        output = output.replacingOccurrences(of: "\r", with: "\\r")
        return output
    }
}

extension LibrarySpaceAuthCoordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        log("didFinish → \(url.absoluteString)")
        if let cas = Self.cas(from: url) {
            Task { @MainActor in
                await exchangeCas(cas)
            }
            return
        }

        if isOnIAM(url), !attemptedPasswordFill {
            attemptedPasswordFill = true
            Task { @MainActor in
                await tryFillIAMLoginFormIfPossible()
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("didFail → \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        log("didFailProvisional → \(error.localizedDescription)")
    }

    private static func cas(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let cas = components.queryItems?.first(where: { $0.name == "cas" })?.value,
           !cas.isEmpty {
            return cas
        }

        guard let fragment = url.fragment,
              let questionIndex = fragment.firstIndex(of: "?") else {
            return nil
        }
        let query = String(fragment[fragment.index(after: questionIndex)...])
        var components = URLComponents()
        components.query = query
        return components.queryItems?.first(where: { $0.name == "cas" })?.value
    }
}

private struct CasUserRequest: Encodable {
    let cas: String
}

private struct WebFetchEnvelope: Decodable {
    let status: Int
    let text: String
}

private struct CasUserResponse: Decodable {
    let code: Int
    let msg: String
    let member: CasUserMember?
}

private struct CasUserMember: Decodable {
    let token: String?
}
