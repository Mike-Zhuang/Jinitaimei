import Foundation
@preconcurrency import WebKit
import os.log

/// 同济统一身份认证（iam.tongji.edu.cn SSO）登录协调器。
///
/// 流程（基于 wish_drom 实战验证的链路 + 真机日志反推）：
///
/// ```
/// 1) 打开 1.tongji.edu.cn/workbench
///    └─► 302 → /ssologin → /api/ssoservice/system/loginIn
///        └─► 302 → iam.tongji.edu.cn/idp/oauth2/authorize…
///            └─► 用户输入账号密码并提交
///                └─► iam 重定向回 1.tongji.edu.cn/api/ssoservice/system/loginIn?code=…
///                    └─► 后端兑换 token → 302 到 http://1.tongji.edu.cn/ssologin?token=…&uid=…&ts=…
///                        └─► 最终落到 https://1.tongji.edu.cn/workbench (SPA)
/// 2) 此时才有真正的 cookie / sessionid / localStorage.sessiondata
///    └─► 用 uid + aesKey + aesIv 做 AES-CBC-PKCS7 加密生成 studentCode
/// 3) 隐式跳转 star.tongji.edu.cn，复用 SSO Cookie 走完二级登录 → XHR 拦截抓 Bearer Token
/// ```
///
/// 关键设计点：
/// - **不在初次 load 时抽取**：WKWebView 一接到 load 请求 `webView.url` 就立刻被设置为目标 URL，
///   KVO 会误报 "已经在 workbench"。必须先用 `hasVisitedSSO` 状态机锁定：只有用户真
///   去过 iam SSO 域再回到 1.tongji.edu.cn 才认为登录完成。
/// - **短轮询而非死等**：登录完成后 SPA bootstrap 通常 2-4 秒就能写入 sessiondata，
///   8 秒轮询足够；一旦拿到立即退出。
@MainActor
public final class TongjiAuthCoordinator: NSObject, ObservableObject {

    public enum Stage: Equatable {
        case idle
        case awaitingUserLogin
        case extractingTongji
        case capturingStarToken
        case finished
        case failed(String)
    }

    @Published public private(set) var stage: Stage = .idle

    public let webView: WKWebView
    private let store: CredentialStore
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "Auth")

    private let tongjiLandingURL = URL(string: "https://1.tongji.edu.cn/workbench")!
    private let starLandingURL = URL(string: "https://star.tongji.edu.cn")!

    /// 用户是否曾经到访过 iam SSO 页面。只有"曾去过 SSO + 现在回到 1.tongji.edu.cn"
    /// 才视作真正的登录成功，避免初次 load workbench 时被误判。
    private var hasVisitedSSO = false
    private var tongjiExtracted = false
    private var tongjiExtractionTask: Task<Void, Never>?
    private var starCaptureTask: Task<Void, Never>?
    private var urlObservation: NSKeyValueObservation?

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // 桌面 UA 可避免一些移动版页面引导，但同济 SSO 移动适配较好，先保持默认。
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
        starCaptureTask?.cancel()
        starCaptureTask = nil

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

    /// 用户是否当前停留在一系统主站（登录完成的标志页）。
    private func isOnTongjiMainSite(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "1.tongji.edu.cn"
    }

    private func isOnSSO(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "iam.tongji.edu.cn" || host == "ids.tongji.edu.cn"
    }

    private func isStarURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "star.tongji.edu.cn"
            && !url.path.lowercased().contains("/login")
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

        // 卓越星阶段
        if tongjiExtracted && isStarURL(url) {
            startStarCapture()
            return
        }

        // 一系统抽取阶段：必须先去过 SSO，再回到 1.tongji.edu.cn 才认为登录完成
        if !tongjiExtracted && hasVisitedSSO && isOnTongjiMainSite(url) {
            startTongjiExtraction()
        }
    }

    // MARK: - 阶段 1：提取一系统凭证

    private func startTongjiExtraction() {
        guard tongjiExtractionTask == nil else { return }
        stage = .extractingTongji
        log("登录回调已检测到，启动一系统凭证抽取")

        tongjiExtractionTask = Task { @MainActor in
            // SPA bootstrap 时间
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await extractTongjiCredentialsWithRetry()
            self.tongjiExtractionTask = nil
        }
    }

    private func extractTongjiCredentialsWithRetry() async {
        // 8 次轮询（约 8 秒），覆盖一系统 SPA 的 bootstrap 时间窗口
        for attempt in 1...8 {
            log("一系统抽取尝试 #\(attempt)")
            if await tryExtractOnce(attempt: attempt) {
                tongjiExtracted = true
                log("一系统凭证抽取完成，开始跳转 STAR")
                stage = .capturingStarToken
                webView.load(URLRequest(url: starLandingURL))
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        log("一系统抽取失败：8 秒内未能拿到完整凭证")
        stage = .failed("登录信息获取超时，请退出后重试")
    }

    /// 单次抽取尝试。Cookie 和 sessiondata 都必须就绪才视作成功。
    private func tryExtractOnce(attempt: Int) async -> Bool {
        let cookieStr = await tryGetCookieString()
        guard let cookieStr, !cookieStr.isEmpty else {
            log("  Cookie 仍未就绪")
            return false
        }
        log("  Cookie 已就绪 (len=\(cookieStr.count))")

        let sessionDataRaw = try? await webView.evaluateJavaScript("localStorage.getItem('sessiondata')")
        guard let sessionData = JSONUtils.normalizeJavaScriptValue(sessionDataRaw) else {
            log("  sessiondata 尚未写入 localStorage")
            return false
        }
        log("  sessiondata 已就绪 (len=\(sessionData.count))")

        store.set(cookieStr, for: CredentialStore.Keys.tongjiCookies)

        if let sessionId = await trySessionId() {
            store.set(sessionId, for: CredentialStore.Keys.tongjiSessionId)
            log("  sessionId(X-Token) 已存储")
        } else {
            log("  sessionId(X-Token) 未取到（某些后端不强制此头，先继续）")
        }

        let uid = JSONUtils.extractTopLevelField(sessionData, field: "uid")
        let aesKey = JSONUtils.extractTopLevelField(sessionData, field: "aesKey")
        let aesIv = JSONUtils.extractTopLevelField(sessionData, field: "aesIv")
        log("  uid=\(uid != nil) aesKey=\(aesKey != nil) aesIv=\(aesIv != nil)")

        if let uid { store.set(uid, for: CredentialStore.Keys.tongjiUid) }
        if let aesKey { store.set(aesKey, for: CredentialStore.Keys.tongjiAesKey) }
        if let aesIv { store.set(aesIv, for: CredentialStore.Keys.tongjiAesIv) }

        if let uid, let aesKey, let aesIv {
            do {
                let studentCode = try StudentCodeCipher.encryptStudentCode(
                    uid: uid, aesKey: aesKey, aesIv: aesIv
                )
                store.set(studentCode, for: CredentialStore.Keys.tongjiStudentCode)
                log("  studentCode 已加密并存储")
            } catch {
                log("  studentCode 加密失败: \(error)")
            }
        }
        return true
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

        // 原生 WKHTTPCookieStore 回退（HttpOnly 场景必备）
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

    // MARK: - 阶段 2：抓 STAR Bearer Token

    private func startStarCapture() {
        guard starCaptureTask == nil else { return }
        log("开始 STAR Bearer Token 抓取")
        starCaptureTask = Task { @MainActor in
            await captureStarToken()
            self.starCaptureTask = nil
        }
    }

    private func captureStarToken() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        _ = try? await webView.evaluateJavaScript(
            "XMLHttpRequest.prototype.sH=XMLHttpRequest.prototype.setRequestHeader"
        )
        _ = try? await webView.evaluateJavaScript(
            "window.__fn=String.fromCharCode(102,117,110,99,116,105,111,110)"
        )
        _ = try? await webView.evaluateJavaScript("window.__xf=window.__fn+'(k,v){'")
        _ = try? await webView.evaluateJavaScript(
            "window.__xf+='if(k.toLowerCase()==\"authorization\")window.__xhr_t=v;'"
        )
        _ = try? await webView.evaluateJavaScript(
            "window.__xf+='return this.sH.apply(this,arguments)}'"
        )
        _ = try? await webView.evaluateJavaScript("window.__xhr_t=''")
        _ = try? await webView.evaluateJavaScript(
            "window.__xa='XMLHttpRequest.prototype.setRequestHeader='"
        )
        _ = try? await webView.evaluateJavaScript("eval(window.__xa+window.__xf)")
        log("STAR XHR 拦截器已注入")

        let uniRaw = try? await webView.evaluateJavaScript(
            "typeof uni!=='undefined'&&uni.request?1:0"
        )
        if JSONUtils.normalizeJavaScriptValue(uniRaw) == "1" {
            _ = try? await webView.evaluateJavaScript("window.__uc={}")
            _ = try? await webView.evaluateJavaScript(
                "window.__uc.url='/api/app-api/activity/index/list'"
            )
            _ = try? await webView.evaluateJavaScript(
                "window.__uc.data={pageNo:1,pageSize:1,recommend:1}"
            )
            _ = try? await webView.evaluateJavaScript(
                "window.__uc.success=eval(window.__fn+'(r){window.__fb=JSON.stringify(r.data)}')"
            )
            _ = try? await webView.evaluateJavaScript("uni.request(window.__uc)")
            log("STAR uni.request 已主动触发")
        }
        _ = try? await webView.evaluateJavaScript(
            "location.hash='__probe__'+Date.now()"
        )

        for attempt in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let raw = try? await webView.evaluateJavaScript("window.__xhr_t||''"),
               let token = JSONUtils.normalizeJavaScriptValue(raw), !token.isEmpty {
                let stripped = stripBearerPrefix(token)
                store.set(stripped, for: CredentialStore.Keys.starBearerToken)
                log("STAR Bearer Token 已抓到 (\(attempt + 1)s, len=\(stripped.count))")
                stage = .finished
                return
            }
        }
        log("STAR Token 抓取超时，但一系统已就绪，登录视为完成")
        stage = .finished
    }

    private func stripBearerPrefix(_ token: String) -> String {
        if token.lowercased().hasPrefix("bearer ") {
            return String(token.dropFirst(7))
        }
        return token
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
