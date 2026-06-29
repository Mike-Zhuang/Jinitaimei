import Foundation
@preconcurrency import WebKit
import os.log

@MainActor
public final class WaterAuthCoordinator: NSObject, ObservableObject {
    public static let shared = WaterAuthCoordinator()

    public let webView: WKWebView

    private let store: CredentialStore
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "WaterAuth")
    private var renewTask: Task<Bool, Never>?

    private let payOrigin = "https://pay-yikatong.tongji.edu.cn"
    private let ksOrigin = "https://ks.tongji.edu.cn"

    private var waterLoginURL: URL {
        let platURL = "\(payOrigin)/plat?loginFrom=h5"
        let inner = "\(payOrigin)/berserker-base/redirect?type=url&url=\(Self.percentEncode(platURL))"
        return URL(string: "\(payOrigin)/berserker-auth/cas/redirect/bamboocloud?targetUrl=\(Self.percentEncode(inner))")!
    }

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    public func renewIfPossible(force: Bool = false) async -> Bool {
        if !force, hasAuthParams() {
            return true
        }
        if let renewTask { return await renewTask.value }

        let task = Task<Bool, Never> { @MainActor in
            await restoreStoredCookies()
            log("启动智能控水鉴权")

            var token = storedYikatongToken()
            if token == nil {
                _ = await YikatongAuthCoordinator.shared.renewIfPossible()
                token = storedYikatongToken()
            }

            if let token {
                log("使用一卡通 Token 跳转水控，长度=\(token.count)")
                webView.load(URLRequest(url: waterRedirectURL(token: token)))
            } else {
                log("未找到一卡通 Token，尝试从 pay 入口进入水控")
                webView.load(URLRequest(url: waterLoginURL))
            }

            var loadedFallbackEntry = false
            for tick in 0..<26 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                if let url = webView.url,
                   url.host?.contains("pay-yikatong.tongji.edu.cn") == true,
                   let captured = extractSynjonesAuth(from: url.absoluteString) {
                    log("从 pay 回跳捕获水控 synjones-auth，长度=\(captured.count)")
                    webView.load(URLRequest(url: waterRedirectURL(token: captured)))
                    continue
                }

                if let url = webView.url,
                   url.host?.contains("ks.tongji.edu.cn") == true,
                   await tryStoreParamsFromKSPage() {
                    log("智能控水鉴权参数已就绪")
                    return true
                }

                if tick == 8, !loadedFallbackEntry, webView.url?.host?.contains("ks.tongji.edu.cn") != true {
                    loadedFallbackEntry = true
                    log("尚未进入 ks 域，改走 pay 登录入口兜底")
                    webView.load(URLRequest(url: waterLoginURL))
                }

                if tick == 5 || tick == 14 || tick == 25 {
                    log("等待水控回跳中，当前 URL=\(redactedURLForLog(webView.url))")
                }
            }

            log("智能控水鉴权超时")
            return false
        }

        renewTask = task
        let result = await task.value
        renewTask = nil
        return result
    }

    public func clearCredentials() {
        store.remove(CredentialStore.Keys.waterControlAccount)
        store.remove(CredentialStore.Keys.waterControlAesKey)
        store.remove(CredentialStore.Keys.waterControlPassword)
        store.remove(CredentialStore.Keys.waterControlCookies)
        store.remove(CredentialStore.Keys.waterControlApiToken)
        store.remove(CredentialStore.Keys.waterControlApiTokenSavedAt)
    }

    public func hasAuthParams() -> Bool {
        guard store.get(CredentialStore.Keys.waterControlAccount)?.isEmpty == false,
              store.get(CredentialStore.Keys.waterControlAesKey)?.isEmpty == false,
              store.get(CredentialStore.Keys.waterControlPassword)?.isEmpty == false else {
            return false
        }
        return true
    }

    public func fetchKSData(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        if webView.url?.host?.contains("ks.tongji.edu.cn") != true {
            let renewed = await renewIfPossible(force: true)
            guard renewed else {
                throw AuthError.expired("水控 WebView 登录态不可用")
            }
        }

        var components = URLComponents()
        components.path = path.hasPrefix("/") ? path : "/" + path
        components.queryItems = queryItems
        guard let relativeURL = components.string else {
            throw AuthError.loginFlowFailed("水控同源请求 URL 构造失败")
        }

        log("水控 WebView 同源请求 path=\(path) queryKeys=\(queryItems.map(\.name).joined(separator: ","))")
        let script = """
        const response = await fetch(url, {
            method: 'GET',
            credentials: 'include',
            headers: { 'Accept': 'application/json, text/plain, */*' }
        });
        const text = await response.text();
        return JSON.stringify({ status: response.status, ok: response.ok, text: text });
        """
        let raw = try await webView.callAsyncJavaScript(
            script,
            arguments: ["url": relativeURL],
            in: nil,
            contentWorld: .page
        )
        guard let normalized = JSONUtils.normalizeJavaScriptValue(raw),
              let data = normalized.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.loginFlowFailed("水控同源请求结果无法解析")
        }
        let status = dict["status"] as? Int ?? -1
        let ok = dict["ok"] as? Bool ?? false
        let text = dict["text"] as? String ?? ""
        log("水控 WebView 同源响应 path=\(path) HTTP=\(status) bodyLen=\(text.count)")
        if status == 401 || status == 403 {
            throw AuthError.expired("水控 WebView 登录态已失效")
        }
        guard ok else {
            throw AuthError.loginFlowFailed("水控同源请求 HTTP \(status)")
        }
        return Data(text.utf8)
    }

    private func tryStoreParamsFromKSPage() async -> Bool {
        await syncKSCookiesFromWebView()

        guard let account = await extractAccount(), !account.isEmpty else {
            log("水控页面未提取到 ano")
            return false
        }

        let jsTexts = await fetchJSTexts()
        let aesKey = WaterControlCipher.findAesKey(in: jsTexts) ?? WaterControlCipher.defaultAesKey
        let password = WaterControlCipher.findPassword(in: jsTexts) ?? WaterControlCipher.defaultPassword
        let previousAccount = store.get(CredentialStore.Keys.waterControlAccount)
        let previousAesKey = store.get(CredentialStore.Keys.waterControlAesKey)
        let previousPassword = store.get(CredentialStore.Keys.waterControlPassword)
        let paramsChanged = previousAccount != account || previousAesKey != aesKey || previousPassword != password

        store.set(account, for: CredentialStore.Keys.waterControlAccount)
        store.set(aesKey, for: CredentialStore.Keys.waterControlAesKey)
        store.set(password, for: CredentialStore.Keys.waterControlPassword)
        if paramsChanged {
            store.remove(CredentialStore.Keys.waterControlApiToken)
            store.remove(CredentialStore.Keys.waterControlApiTokenSavedAt)
        }

        let aesSource = aesKey == WaterControlCipher.defaultAesKey ? "fallback" : "js"
        let passwordSource = password == WaterControlCipher.defaultPassword ? "fallback" : "js"
        log("水控参数已保存：accountLen=\(account.count) aes=\(aesSource) password=\(passwordSource) jsTexts=\(jsTexts.count) paramsChanged=\(paramsChanged)")
        return true
    }

    private func extractAccount() async -> String? {
        let script = """
        (function() {
            var sessionAno = sessionStorage.getItem('ano') || '';
            if (sessionAno) return JSON.stringify({ value: sessionAno, source: 'sessionStorage' });
            var localAno = localStorage.getItem('ano') || '';
            if (localAno) return JSON.stringify({ value: localAno, source: 'localStorage' });
            var windowAno = window.ano || '';
            if (windowAno) return JSON.stringify({ value: String(windowAno), source: 'window' });
            return JSON.stringify({ value: '', source: 'none' });
        })();
        """
        let raw = try? await webView.evaluateJavaScript(script)
        guard let normalized = JSONUtils.normalizeJavaScriptValue(raw),
              let data = normalized.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("水控 ano 提取结果无法解析")
            return nil
        }
        let value = (dict["value"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmptyValue
        let source = (dict["source"] as? String) ?? "unknown"
        log("水控 ano 提取 source=\(source) len=\(value?.count ?? 0)")
        return value
    }

    private func fetchJSTexts() async -> [String] {
        let urls = await collectJSURLs()
        guard !urls.isEmpty else {
            log("水控页面未发现 JS 文件，使用 fallback 参数")
            return []
        }
        log("水控页面发现 JS 文件 count=\(urls.count) names=\(summarizeJSURLs(urls))")
        let script = """
        var texts = [];
        for (const url of urls) {
            try {
                const response = await fetch(url);
                if (response.ok) {
                    const text = await response.text();
                    if (text) texts.push(text);
                }
            } catch (e) {}
        }
        return JSON.stringify({ texts: texts });
        """
        do {
            let raw = try await webView.callAsyncJavaScript(
                script,
                arguments: ["urls": urls],
                in: nil,
                contentWorld: .page
            )
            let normalized = JSONUtils.normalizeJavaScriptValue(raw) ?? ""
            guard let data = normalized.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let texts = dict["texts"] as? [String] else {
                return []
            }
            log("水控 JS 文本获取完成 count=\(texts.count)")
            return texts
        } catch {
            log("水控 JS 文本获取失败：\(error.localizedDescription)")
            return []
        }
    }

    private func collectJSURLs() async -> [String] {
        let script = """
        (function() {
            const scripts = Array.from(document.scripts).map(s => s.src).filter(Boolean);
            let resources = [];
            try {
                resources = performance.getEntriesByType('resource')
                    .map(e => e.name)
                    .filter(name => String(name).includes('.js'));
            } catch (e) {}
            return JSON.stringify({ scripts: scripts, resources: resources });
        })();
        """
        guard let raw = try? await webView.evaluateJavaScript(script),
              let normalized = JSONUtils.normalizeJavaScriptValue(raw),
              let data = normalized.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let candidates = ((dict["scripts"] as? [String]) ?? []) + ((dict["resources"] as? [String]) ?? [])
        var seen = Set<String>()
        var result: [String] = []
        for value in candidates {
            guard let url = normalizeKSJSURL(value),
                  !seen.contains(url) else { continue }
            seen.insert(url)
            result.append(url)
        }
        return result
    }

    private func normalizeKSJSURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(".js") else { return nil }
        if trimmed.hasPrefix(ksOrigin) {
            return trimmed
        }
        if trimmed.hasPrefix("/") {
            return ksOrigin + trimmed
        }
        return nil
    }

    private func summarizeJSURLs(_ urls: [String]) -> String {
        urls.prefix(6)
            .map { URL(string: $0)?.lastPathComponent.nilIfEmptyValue ?? "<unknown>" }
            .joined(separator: ",")
    }

    private func syncKSCookiesFromWebView() async {
        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let ksCookies = cookies.filter { item in
            cookieMatches(item, host: "ks.tongji.edu.cn")
        }
        guard !ksCookies.isEmpty else { return }
        CookieJar.shared.mergeNative(ksCookies)
        let header = ksCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        if !header.isEmpty {
            store.set(header, for: CredentialStore.Keys.waterControlCookies)
            log("已同步水控 Cookie，count=\(ksCookies.count)，names=\(ksCookies.map(\.name).sorted().joined(separator: ","))")
        }
    }

    private func cookieMatches(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    private func restoreStoredCookies() async {
        let count = await CookieJar.shared.restoreCookies(
            to: webView.configuration.websiteDataStore.httpCookieStore,
            hostSuffix: "tongji.edu.cn"
        )
        if count > 0 {
            log("已向水控 WebView 回灌同济 Cookie，count=\(count)")
        }
    }

    private func storedYikatongToken() -> String? {
        store.get(CredentialStore.Keys.yikatongBearerToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmptyValue
    }

    private func waterRedirectURL(token: String) -> URL {
        let encoded = Self.percentEncode(token)
        return URL(string: "\(payOrigin)/berserker-base/redirect?appId=240&type=app&synjones-auth=\(encoded)&synAccessSource=wechat-work&loginFrom=wechat-work")!
    }

    private func extractSynjonesAuth(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let raw = components.queryItems?.first(where: { $0.name == "synjones-auth" })?.value,
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func redactedURLForLog(_ url: URL?) -> String {
        guard let url else { return "nil" }
        let sensitiveNames = [
            "synjones-auth",
            "token",
            "ticket",
            "cas",
            "code",
            "sessionid"
        ]
        var redacted = url.absoluteString
        for name in sensitiveNames {
            redacted = redacted.replacingOccurrences(
                of: "([?&#]|%3F|%26)(\(NSRegularExpression.escapedPattern(for: name)))(=|%3D)[^&#]+",
                with: "$1$2$3<redacted>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return redacted
    }

    private func log(_ message: String) {
        logger.debug("[WaterAuth] \(message, privacy: .public)")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

extension WaterAuthCoordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("didFinish → \(redactedURLForLog(webView.url))")
    }
}

private extension String {
    var nilIfEmptyValue: String? {
        isEmpty ? nil : self
    }
}
