import Foundation
@preconcurrency import WebKit

/// 同济统一身份认证（ids/iam.tongji.edu.cn SSO）登录协调器。
///
/// 设计：用户只需走一遍 SSO，本协调器在同一 WKWebView 中按序完成两件事：
/// 1. 落地 `https://1.tongji.edu.cn/workbench`，提取一系统凭证
///    （Cookie / sessionid / `localStorage.sessiondata` 中的 uid+aesKey+aesIv），
///    再生成加密 `studentCode` 一并存入 Keychain。
/// 2. 隐式跳转 `https://star.tongji.edu.cn`，复用 SSO Cookie 自动登录，
///    注入 XHR 拦截器抓取 Bearer Token 存入 Keychain。
///
/// 移植参考：
/// - `wish_drom/Services/DataProviders/TongjiScheduleProvider.cs`
/// - `wish_drom/Services/DataProviders/StarActivityProvider.cs`
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

    /// 一系统目标 URL：登录后会重定向回这里。
    private let tongjiLandingURL = URL(string: "https://1.tongji.edu.cn/workbench")!
    /// 卓越星目标 URL：登录后跳到这里抓 Bearer Token。
    private let starLandingURL = URL(string: "https://star.tongji.edu.cn")!

    /// 标记一系统凭证是否已抓到（避免在反复跳转中重复抓）。
    private var tongjiExtracted = false

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    /// 开始登录流程：清空旧 WebView 数据后加载一系统首页，触发 SSO 重定向。
    ///
    /// 不清空 cookie 会出现"上次登录残留 cookie 导致 SSO 静默自动完成、
    /// 用户看到登录页一闪而过就关掉"的诡异行为。这里强制每次都重新过 SSO，
    /// 用户能明确看到登录表单。
    public func start() {
        stage = .awaitingUserLogin
        tongjiExtracted = false

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
            self.webView.load(URLRequest(url: self.tongjiLandingURL))
        }
    }

    // MARK: - 内部：URL 判定

    private func isWorkbenchURL(_ url: URL) -> Bool {
        let s = url.absoluteString
        return s.hasPrefix("https://1.tongji.edu.cn/workbench")
            && !s.contains("ids.tongji.edu.cn")
            && !s.contains("iam.tongji.edu.cn")
    }

    private func isStarURL(_ url: URL) -> Bool {
        let s = url.absoluteString
        return s.hasPrefix("https://star.tongji.edu.cn")
            && !s.contains("/login")
            && !s.contains("ids.tongji.edu.cn")
            && !s.contains("iam.tongji.edu.cn")
    }

    // MARK: - 阶段 1：提取一系统凭证

    private func extractTongjiCredentials() async {
        stage = .extractingTongji

        // Cookie
        let cookieStr = await tryGetCookieString()
        guard let cookieStr, !cookieStr.isEmpty else {
            stage = .failed("无法获取一系统 Cookie")
            return
        }
        store.set(cookieStr, for: CredentialStore.Keys.tongjiCookies)

        // sessionid (X-Token)
        if let sessionId = await trySessionId() {
            store.set(sessionId, for: CredentialStore.Keys.tongjiSessionId)
        }

        // sessiondata → uid / aesKey / aesIv → studentCode
        if let sessionData = JSONUtils.normalizeJavaScriptValue(
            try? await webView.evaluateJavaScript("localStorage.getItem('sessiondata')")
        ) {
            let uid = JSONUtils.extractTopLevelField(sessionData, field: "uid")
            let aesKey = JSONUtils.extractTopLevelField(sessionData, field: "aesKey")
            let aesIv = JSONUtils.extractTopLevelField(sessionData, field: "aesIv")

            if let uid { store.set(uid, for: CredentialStore.Keys.tongjiUid) }
            if let aesKey { store.set(aesKey, for: CredentialStore.Keys.tongjiAesKey) }
            if let aesIv { store.set(aesIv, for: CredentialStore.Keys.tongjiAesIv) }

            if let uid, let aesKey, let aesIv {
                if let studentCode = try? StudentCodeCipher.encryptStudentCode(
                    uid: uid, aesKey: aesKey, aesIv: aesIv
                ) {
                    store.set(studentCode, for: CredentialStore.Keys.tongjiStudentCode)
                }
            }
        }

        tongjiExtracted = true
        // 切到 STAR 抓 Bearer Token
        stage = .capturingStarToken
        webView.load(URLRequest(url: starLandingURL))
    }

    private func tryGetCookieString() async -> String? {
        if let raw = try? await webView.evaluateJavaScript("document.cookie"),
           let s = JSONUtils.normalizeJavaScriptValue(raw), !s.isEmpty {
            return s
        }

        // cookieStore.getAll() fallback（异步）
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

        // 原生 cookie 回退（HttpOnly 场景）
        let nativeCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let tongjiCookies = nativeCookies.filter { cookie in
            let d = cookie.domain
            return d.contains("tongji.edu.cn") || d.contains("1.tongji.edu.cn")
        }
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

    /// 注入 XHR 拦截器并轮询 `window.__xhr_t`，移植自 wish_drom
    /// `StarActivityProvider.TryGetTokenViaInterceptionAsync`。
    private func captureStarToken() async {
        do {
            // Step 1: 备份原始 setRequestHeader
            _ = try? await webView.evaluateJavaScript(
                "XMLHttpRequest.prototype.sH=XMLHttpRequest.prototype.setRequestHeader"
            )
            // Step 2: 用 fromCharCode 拼 "function"
            _ = try? await webView.evaluateJavaScript(
                "window.__fn=String.fromCharCode(102,117,110,99,116,105,111,110)"
            )
            // Step 3: 拼接拦截器函数体
            _ = try? await webView.evaluateJavaScript("window.__xf=window.__fn+'(k,v){'")
            _ = try? await webView.evaluateJavaScript(
                "window.__xf+='if(k.toLowerCase()==\"authorization\")window.__xhr_t=v;'"
            )
            _ = try? await webView.evaluateJavaScript(
                "window.__xf+='return this.sH.apply(this,arguments)}'"
            )
            // Step 4: 初始化捕获变量
            _ = try? await webView.evaluateJavaScript("window.__xhr_t=''")
            // Step 5: 用 eval 装载拦截器
            _ = try? await webView.evaluateJavaScript(
                "window.__xa='XMLHttpRequest.prototype.setRequestHeader='"
            )
            _ = try? await webView.evaluateJavaScript("eval(window.__xa+window.__xf)")

            // Step 6: 尝试触发 uni.request 拉一次活动列表
            let uniRaw = try? await webView.evaluateJavaScript(
                "typeof uni!=='undefined'&&uni.request?1:0"
            )
            if JSONUtils.normalizeJavaScriptValue(uniRaw) == "1" {
                _ = try? await webView.evaluateJavaScript("window.__fb=''")
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
            }

            // 触发 hash change，让 SPA 重新触发数据请求
            _ = try? await webView.evaluateJavaScript(
                "location.hash='__probe__'+Date.now()"
            )

            // Step 7: 轮询 token，最多 10 秒
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let raw = try? await webView.evaluateJavaScript("window.__xhr_t||''"),
                   let token = JSONUtils.normalizeJavaScriptValue(raw), !token.isEmpty {
                    let stripped = stripBearerPrefix(token)
                    store.set(stripped, for: CredentialStore.Keys.starBearerToken)
                    stage = .finished
                    return
                }
            }
            // 抓不到 STAR token 不算致命错误，主要的一系统登录已完成
            stage = .finished
        }
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
        guard let url = webView.url else { return }

        if isWorkbenchURL(url) && !tongjiExtracted {
            Task { @MainActor in
                await extractTongjiCredentials()
            }
        } else if tongjiExtracted && isStarURL(url) {
            Task { @MainActor in
                await captureStarToken()
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 单次 navigation 失败不视作流程失败，SSO 会有多次重定向。
    }
}
