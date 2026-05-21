import Foundation
@preconcurrency import WebKit
import os.log

/// 同济统一身份认证（iam.tongji.edu.cn SSO）登录协调器。
///
/// 设计原则（来自真机日志反推）：
///
/// - `WKWebView` 一接到 `load` 请求 `url` 就立即被设置为目标地址，导致 KVO 误报。
///   因此**绝对不能只靠 host 判断登录是否完成**。
/// - SSO 完整链路：`1.tongji.edu.cn/workbench` → `/ssologin` → `/api/ssoservice/system/loginIn`
///   → `iam.tongji.edu.cn/idp/oauth2/authorize` → 用户输密码 → `/api/ssoservice/.../loginIn?code=...`
///   → `http://1.tongji.edu.cn/ssologin?token=...&uid=...&ts=...` → 最终 `https://1.tongji.edu.cn/workbench/...`
/// - 真正可抽取的"workbench SPA 已就绪"判定：**host 是 1.tongji.edu.cn 且 path 以
///   `/workbench` 开头（去除中间页 `/ssologin`、`/api/...`、`/idp/...`）**。
/// - `sessiondata` 在 SPA bootstrap 完成后才写入，必须轮询；只有 `uid` 字段非空
///   才算真正就绪，光长度非零不行（中间页可能写入 "null" 占位）。
///
/// 登录完成以"一系统凭证齐全"为准；STAR Bearer Token 只做 best-effort 抽取，
/// 失败不阻断登录页关闭。
@MainActor
public final class TongjiAuthCoordinator: NSObject, ObservableObject {

    public enum Stage: Equatable {
        case idle
        case awaitingUserLogin
        case extractingTongji
        case extractingStar
        case finished
        case failed(String)
    }

    @Published public private(set) var stage: Stage = .idle

    public let webView: WKWebView
    private let store: CredentialStore
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "Auth")

    private let tongjiLandingURL = URL(string: "https://1.tongji.edu.cn/workbench")!
    private let starMyURL = URL(string: "https://star.tongji.edu.cn/app/pages/index/my")!
    private let starSocialAuthURL = URL(string: "https://star.tongji.edu.cn/api/app-api/system/auth/social-auth-url-redirect?type=36&redirectUri=https://star.tongji.edu.cn/app/pages/login/social")!

    private var hasVisitedSSO = false
    private var tongjiExtracted = false
    private var tongjiExtractionTask: Task<Void, Never>?
    private var urlObservation: NSKeyValueObservation?

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.allowsBackForwardNavigationGestures = false

        self.urlObservation = self.webView.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let self, let url = change.newValue ?? nil else { return }
            Task { @MainActor in
                self.handleURLChange(url)
            }
        }
    }

    deinit {
        urlObservation?.invalidate()
    }

    public func start() {
        log("开始登录流程：清空 WebView 旧数据")
        stage = .awaitingUserLogin
        hasVisitedSSO = false
        tongjiExtracted = false
        tongjiExtractionTask?.cancel()
        tongjiExtractionTask = nil

        let dataStore = webView.configuration.websiteDataStore
        let dataTypes: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeDiskCache
        ]
        dataStore.removeData(
            ofTypes: dataTypes,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) { [weak self] in
            guard let self else { return }
            self.log("WebView 数据已清空，开始加载 \(self.tongjiLandingURL.absoluteString)")
            self.webView.load(URLRequest(url: self.tongjiLandingURL))
        }
    }

    private func log(_ message: String) {
        let line = "[Auth] \(message)"
        print(line)
        logger.info("\(line, privacy: .public)")
    }

    // MARK: - URL 路由判定

    /// 是否到达了真正的 workbench SPA 页面（排除所有中间跳板）。
    private func isOnTongjiWorkbench(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == "1.tongji.edu.cn" else {
            return false
        }
        let path = url.path.lowercased()
        // 中间页排除清单
        if path.hasPrefix("/api/") { return false }
        if path.hasPrefix("/ssologin") { return false }
        if path.hasPrefix("/idp/") { return false }
        // 只认 workbench
        return path.hasPrefix("/workbench") || path == "/" || path.isEmpty
    }

    private func isOnSSO(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "iam.tongji.edu.cn" || host == "ids.tongji.edu.cn"
    }

    private func handleURLChange(_ url: URL) {
        log("URL 变更 → \(url.absoluteString)")

        if isOnSSO(url) {
            if !hasVisitedSSO {
                hasVisitedSSO = true
                log("用户进入 SSO 页面，等待登录完成")
            }
            return
        }

        // 必须满足三个条件：去过 SSO + 现在到了真正 workbench + 还没抽过
        if !tongjiExtracted && hasVisitedSSO && isOnTongjiWorkbench(url) {
            startTongjiExtraction()
        }
    }

    // MARK: - 一系统凭证抽取

    private func startTongjiExtraction() {
        guard tongjiExtractionTask == nil else { return }
        stage = .extractingTongji
        log("workbench 已就绪，启动一系统凭证抽取")

        tongjiExtractionTask = Task { @MainActor in
            // 给 SPA bootstrap 一些时间，再开始轮询 sessiondata
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await extractWithRetry()
            self.tongjiExtractionTask = nil
        }
    }

    private func extractWithRetry() async {
        // 12 次轮询（约 12 秒）覆盖 SPA bootstrap 时间窗口
        for attempt in 1...12 {
            log("一系统抽取尝试 #\(attempt)")
            if await tryExtractOnce() {
                tongjiExtracted = true
                log("一系统凭证抽取完成 ✅")
                stage = .finished
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        log("一系统抽取失败：12 秒内 sessiondata.uid 始终为空")
        stage = .failed("无法获取登录信息，请退出后重试")
    }

    /// 单次抽取：Cookie + sessiondata（含 uid）都到位才算成功。
    private func tryExtractOnce() async -> Bool {
        let cookieStr = await tryGetCookieString()
        guard let cookieStr, !cookieStr.isEmpty else {
            log("  Cookie 仍未就绪")
            return false
        }

        let sessionDataRaw = try? await webView.evaluateJavaScript("localStorage.getItem('sessiondata')")
        guard let sessionData = JSONUtils.normalizeJavaScriptValue(sessionDataRaw),
              sessionData.count > 20  // 排除 "null" / "{}" 之类占位符
        else {
            log("  sessiondata 尚未就绪 (len=\(JSONUtils.normalizeJavaScriptValue(sessionDataRaw)?.count ?? 0))")
            return false
        }

        // 严格校验：必须能解出非空 uid，否则 sessiondata 还没写入真数据
        let uid = JSONUtils.extractTopLevelField(sessionData, field: "uid")
        let aesKey = JSONUtils.extractTopLevelField(sessionData, field: "aesKey")
        let aesIv = JSONUtils.extractTopLevelField(sessionData, field: "aesIv")
        guard let uid, !uid.isEmpty, let aesKey, !aesKey.isEmpty, let aesIv, !aesIv.isEmpty else {
            log("  sessiondata 缺字段 uid=\(uid?.isEmpty == false) aesKey=\(aesKey?.isEmpty == false) aesIv=\(aesIv?.isEmpty == false)")
            return false
        }

        log("  Cookie/sessiondata/uid/aesKey/aesIv 全部就绪")

        // 全部就绪，存盘
        store.set(cookieStr, for: CredentialStore.Keys.tongjiCookies)
        store.set(uid, for: CredentialStore.Keys.tongjiUid)
        store.set(aesKey, for: CredentialStore.Keys.tongjiAesKey)
        store.set(aesIv, for: CredentialStore.Keys.tongjiAesIv)

        if let sessionId = await trySessionId() {
            store.set(sessionId, for: CredentialStore.Keys.tongjiSessionId)
            log("  sessionId(X-Token) 已存储")
        }

        do {
            let studentCode = try StudentCodeCipher.encryptStudentCode(
                uid: uid, aesKey: aesKey, aesIv: aesIv
            )
            store.set(studentCode, for: CredentialStore.Keys.tongjiStudentCode)
            log("  studentCode 已加密并存储")
        } catch {
            log("  studentCode 加密失败: \(error)")
            return false
        }

        do {
            _ = try await SessionAPI(store: store).refreshSessionUser()
            log("  个人信息已拉取并存储")
        } catch {
            // 个人信息用于设置页展示，失败不应阻断已完成的一系统登录。
            log("  个人信息拉取失败: \(error)")
        }
        await extractStarCredentialBestEffort()
        return true
    }

    /// 抽取 STAR Bearer Token 并刷新个人星值。
    ///
    /// 移植自 `wish_drom/Services/DataProviders/StarActivityProvider.cs` 的 XHR
    /// `setRequestHeader` 拦截思路。STAR 是附加能力，失败时只记录日志。
    private func extractStarCredentialBestEffort() async {
        stage = .extractingStar
        log("  开始同步 STAR 平台个人星值")

        webView.load(URLRequest(url: starSocialAuthURL))

        var token = await tryExchangeStarSocialToken()
        if token == nil {
            token = await tryExtractStarToken()
        }
        if let token {
            store.set(token, for: CredentialStore.Keys.starBearerToken)
            log("  STAR Bearer Token 已存储 (len=\(token.count))")
            do {
                _ = try await ActivityAPI(store: store).fetchStarScoreSummary()
                log("  STAR 个人星值已拉取并存储")
            } catch {
                log("  STAR 个人星值拉取失败: \(error)")
            }
        } else {
            log("  STAR Bearer Token 抽取失败，保留同济登录结果")
        }
    }

    /// STAR 自身的登录链路：先让 WebView 走同济 IAM SSO，再用回跳 URL 的 code/state
    /// 调 `/api/app-api/system/auth/social-login` 换取 accessToken。
    private func tryExchangeStarSocialToken() async -> String? {
        guard let callback = await waitForStarSocialCallback() else {
            log("  STAR social-login 回跳未出现，尝试 XHR 拦截兜底")
            return nil
        }
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components?.queryItems?.first(where: { $0.name == "state" })?.value,
              !code.isEmpty, !state.isEmpty else {
            log("  STAR social-login 回跳缺少 code/state")
            return nil
        }

        do {
            let token = try await requestStarAccessToken(code: code, state: state)
            webView.load(URLRequest(url: starMyURL))
            return token
        } catch {
            log("  STAR social-login 换 token 失败: \(error)")
            return nil
        }
    }

    private func waitForStarSocialCallback() async -> URL? {
        for _ in 0..<18 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let url = webView.url,
                  url.host?.lowercased() == "star.tongji.edu.cn",
                  url.path.lowercased().hasPrefix("/app/pages/login/social") else {
                continue
            }
            return url
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
        request.setValue("https://star.tongji.edu.cn/app/pages/login/social?code=\(code)&state=\(state)&type=36", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONEncoder().encode(StarSocialLoginRequest(type: "36", code: code, state: state))

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

    private func tryExtractStarToken() async -> String? {
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

        let scripts = [
            "XMLHttpRequest.prototype.sH=XMLHttpRequest.prototype.setRequestHeader",
            "window.__fn=String.fromCharCode(102,117,110,99,116,105,111,110)",
            "window.__xf=window.__fn+'(k,v){'",
            "window.__xf+='if(k&&k.toLowerCase()==\"authorization\")window.__xhr_t=v;'",
            "window.__xf+='return this.sH.apply(this,arguments)}'",
            "window.__xhr_t=''",
            "window.__xa='XMLHttpRequest.prototype.setRequestHeader='",
            "eval(window.__xa+window.__xf)"
        ]
        for script in scripts {
            _ = try? await webView.evaluateJavaScript(script)
        }

        let triggerScripts = [
            "window.__fb=''",
            "window.__uc={}",
            "window.__uc.url='/api/app-api/activity/statistics/start-count'",
            "window.__uc.method='GET'",
            "window.__uc.header={platform:'h5'}",
            "window.__uc.success=eval(window.__fn+'(r){window.__fb=JSON.stringify(r.data)}')",
            "if(typeof uni!=='undefined'&&uni.request){uni.request(window.__uc)}",
            "fetch('/api/app-api/activity/statistics/start-count',{headers:{platform:'h5'}}).catch(function(){})",
            "location.hash='__probe__'+Date.now()"
        ]
        for script in triggerScripts {
            _ = try? await webView.evaluateJavaScript(script)
        }

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let raw = try? await webView.evaluateJavaScript("window.__xhr_t||''"),
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

    private func tryGetCookieString() async -> String? {
        if let raw = try? await webView.evaluateJavaScript("document.cookie"),
           let s = JSONUtils.normalizeJavaScriptValue(raw), !s.isEmpty {
            return s
        }

        let cookieStoreJS = """
        (async () => {
            if (window.cookieStore && window.cookieStore.getAll) {
                try {
                    const all = await window.cookieStore.getAll();
                    return all.map(c => `${c.name}=${c.value}`).join('; ');
                } catch (e) { return ''; }
            }
            return '';
        })()
        """
        if let raw = try? await webView.evaluateJavaScript(cookieStoreJS),
           let s = JSONUtils.normalizeJavaScriptValue(raw), !s.isEmpty {
            return s
        }

        let nativeCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let tongjiCookies = nativeCookies.filter { $0.domain.contains("tongji.edu.cn") }
        if !tongjiCookies.isEmpty {
            return tongjiCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }

    private func trySessionId() async -> String? {
        let probes = [
            "sessionStorage.getItem('sessionid')",
            "sessionStorage.getItem('sessionId')",
            "localStorage.getItem('sessionid')",
            "localStorage.getItem('sessionId')"
        ]
        for probe in probes {
            if let raw = try? await webView.evaluateJavaScript(probe),
               let s = JSONUtils.normalizeJavaScriptValue(raw), !s.isEmpty {
                return s
            }
        }
        return nil
    }
}

extension TongjiAuthCoordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            log("didFinish → \(url.absoluteString)")
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("didFail → \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("didFailProvisional → \(error.localizedDescription)")
    }
}

private struct StarSocialLoginRequest: Encodable {
    let type: String
    let code: String
    let state: String
}

private struct StarSocialLoginResponse: Decodable {
    let code: Int
    let data: StarSocialLoginData?
    let msg: String?
}

private struct StarSocialLoginData: Decodable {
    let accessToken: String?
}
