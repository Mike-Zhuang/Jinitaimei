import Foundation
@preconcurrency import WebKit
import os.log

/// 同济统一身份认证（iam.tongji.edu.cn SSO）登录协调器。
///
/// 三种入口：
///
/// 1. `startFreshInteractiveLogin()`：用户主动重登。**会清 WebView 数据**，
///    确保看到完整 SSO 表单。
/// 2. `attemptSilentRenew()`：API 401 触发的静默续期。**不清 WebView 数据**，
///    复用 IAM cookie；只要 IAM SSO 没过期就能自动回 workbench 抽出新 sessiondata。
/// 3. `attemptPasswordRelogin(username:password:)`：L1 失败后兜底。
///    JS 注入填表 + 提交；遇到验证码 / MFA 抛 `AuthError.mfaRequired` 降级。
///
/// STAR 抽取已**完全剥离**到 [StarAuthCoordinator]，本类只关心一系统。
///
/// 工作机制要点：
/// - 完成判定不能只看 host，必须 `host == 1.tongji.edu.cn && path 以 /workbench 开头
///   && 排除 /api/* /ssologin /idp/*`，否则会被中间跳板误判。
/// - `sessiondata` 必须 SPA bootstrap 完成后才写入，要轮询；只有 `uid` 字段非空
///   才算真正就绪（中间页会先写 "null" 占位）。
/// - Cookie 取值优先级：**先 `WKHTTPCookieStore.allCookies()`**（能拿到 HttpOnly），
///   再 `cookieStore.getAll()`（JS API），最后 `document.cookie`。
@MainActor
public final class TongjiAuthCoordinator: NSObject, ObservableObject {

    public enum Stage: Equatable {
        case idle
        case awaitingUserLogin
        case extractingTongji
        case finished
        case failed(String)
    }

    @Published public private(set) var stage: Stage = .idle

    /// 交互登录期间用户在 IAM 表单里实际输入的账号 / 密码（JS 抓取）。
    /// 仅在内存中保留，登录完成后由 `LoginPage` 询问是否落 Keychain。
    @Published public private(set) var capturedUsername: String = ""
    @Published public private(set) var capturedPassword: String = ""

    public let webView: WKWebView
    private let store: CredentialStore
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "Auth")

    private let tongjiLandingURL = URL(string: "https://1.tongji.edu.cn/workbench")!

    private var hasVisitedSSO = false
    private var tongjiExtracted = false
    private var extractionTask: Task<Bool, Never>?
    private var urlObservation: NSKeyValueObservation?

    /// 当前流程模式，影响"完成"语义与是否清 WebView 数据。
    private enum Mode { case interactive, silent, passwordFill }
    private var currentMode: Mode = .interactive
    private var silentRenewContinuation: CheckedContinuation<Bool, Never>?

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // 注入凭证抓取脚本（DOM 加载完就监听表单 submit，把用户输入捕获到 window 变量）
        let captureJS = """
        (function() {
            if (window.__tjAuthCaptureInstalled) return;
            window.__tjAuthCaptureInstalled = true;
            window.__capturedUser = '';
            window.__capturedPass = '';
            function tryCapture() {
                document.querySelectorAll('form').forEach(function(f) {
                    if (f.__tjBound) return;
                    f.__tjBound = true;
                    f.addEventListener('submit', function() {
                        try {
                            var u = f.querySelector('input[type="text"], input[name="j_username"], input[name="username"], input[id="username"]');
                            var p = f.querySelector('input[type="password"], input[name="j_password"], input[name="password"], input[id="password"]');
                            if (u && u.value) window.__capturedUser = u.value;
                            if (p && p.value) window.__capturedPass = p.value;
                        } catch (e) {}
                    }, true);
                });
            }
            tryCapture();
            new MutationObserver(tryCapture).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        let captureScript = WKUserScript(
            source: captureJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(captureScript)

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

    // MARK: - 入口

    /// 用户在 UI 里点击"登录"时调用：清空 WebView 数据并加载入口。
    public func startFreshInteractiveLogin() {
        log("交互登录：清空 WebView 旧数据")
        resetState(mode: .interactive)
        stage = .awaitingUserLogin

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
            self.capturedUsername = ""
            self.capturedPassword = ""
            self.log("WebView 数据已清空，加载 \(self.tongjiLandingURL.absoluteString)")
            self.webView.load(URLRequest(url: self.tongjiLandingURL))
        }
    }

    /// 兼容旧 API。生产代码请改用 `startFreshInteractiveLogin()`。
    public func start() { startFreshInteractiveLogin() }

    /// 隐藏续期：不清数据，直接 load workbench，复用 IAM cookie。
    ///
    /// 成功条件：8 秒内走到 workbench SPA 并抽出 sessiondata.uid。
    /// 失败条件：长时间停在 iam / ids，说明 IAM SSO 也过期；或抽取轮询超时。
    public func attemptSilentRenew() async -> Bool {
        log("静默续期启动（不清 WebView 数据）")
        resetState(mode: .silent)
        stage = .extractingTongji

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            silentRenewContinuation = continuation
            webView.load(URLRequest(url: tongjiLandingURL))

            // 总预算：12 秒（IAM 跳一两跳 + SPA bootstrap + 抽取轮询）
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self else { return }
                if let c = self.silentRenewContinuation {
                    self.silentRenewContinuation = nil
                    self.log("静默续期总预算耗尽，判失败")
                    self.stage = .failed("静默续期超时")
                    c.resume(returning: false)
                }
            }
        }
    }

    /// 密码自动回填续期。在 silent 模式 webview 上跑，结束后报告成功/失败/MFA。
    ///
    /// 流程：清掉 IAM 域 cookie（这是关键——只有 IAM cookie 失效时才会被调用，
    /// 旧 cookie 反而会让我们卡在"IAM 试图跳回但被自家中间页拦"），重新 load workbench
    /// → IAM 弹出表单 → JS 自动填表提交 → 等待跳回 workbench。
    public func attemptPasswordRelogin(username: String, password: String) async throws -> Bool {
        guard !username.isEmpty, !password.isEmpty else { return false }
        log("密码回填登录启动 user=\(maskedUsername(username))")
        resetState(mode: .passwordFill)
        stage = .awaitingUserLogin
        capturedUsername = username  // 记下来以便复用 capture 逻辑
        capturedPassword = password

        // 先把 IAM 域的旧 cookie 清掉，让 IAM 重新出表单
        await clearCookies(forDomainSuffix: "iam.tongji.edu.cn")
        await clearCookies(forDomainSuffix: "ids.tongji.edu.cn")

        webView.load(URLRequest(url: tongjiLandingURL))

        // 监听 5 秒：如果到了 IAM 表单页面就注入填表
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let url = webView.url, isOnSSO(url) {
                if try await detectMFAOrFillAndSubmit(username: username, password: password) {
                    break
                }
            }
            // 若 IAM cookie 其实还没过期，可能直接跳回 workbench
            if let url = webView.url, isOnTongjiWorkbench(url) {
                break
            }
        }

        // 后续依赖普通流程：handleURLChange 检测到 workbench 后会抽取并 resume continuation
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            silentRenewContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                if let c = self.silentRenewContinuation {
                    self.silentRenewContinuation = nil
                    self.log("密码回填总预算耗尽，判失败")
                    self.stage = .failed("密码回填超时")
                    c.resume(returning: false)
                }
            }
        }
    }

    // MARK: - URL 路由判定

    private func isOnTongjiWorkbench(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == "1.tongji.edu.cn" else { return false }
        let path = url.path.lowercased()
        if path.hasPrefix("/api/") { return false }
        if path.hasPrefix("/ssologin") { return false }
        if path.hasPrefix("/idp/") { return false }
        return path.hasPrefix("/workbench") || path == "/" || path.isEmpty
    }

    private func isOnSSO(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "iam.tongji.edu.cn" || host == "ids.tongji.edu.cn"
    }

    private func handleURLChange(_ url: URL) {
        log("URL → \(url.absoluteString)")

        if isOnSSO(url) {
            if !hasVisitedSSO {
                hasVisitedSSO = true
                log("命中 SSO，等待登录完成")
            }
            return
        }

        // 静默续期和密码回填模式：第一次到 workbench 就允许抽（hasVisitedSSO 可能没经过）
        let bypass = currentMode != .interactive
        let workbenchReady = isOnTongjiWorkbench(url)
        let canExtract = workbenchReady && !tongjiExtracted && (hasVisitedSSO || bypass)
        if canExtract {
            startTongjiExtraction()
        }
    }

    // MARK: - 一系统凭证抽取

    private func startTongjiExtraction() {
        guard extractionTask == nil else { return }
        stage = .extractingTongji
        log("workbench 已就绪，开始抽取")

        extractionTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            // SPA bootstrap 缓冲
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let ok = await self.extractWithRetry()
            self.extractionTask = nil
            self.finishCurrentMode(success: ok)
            return ok
        }
    }

    private func extractWithRetry() async -> Bool {
        for attempt in 1...12 {
            log("抽取尝试 #\(attempt)")
            if await tryExtractOnce() {
                tongjiExtracted = true
                log("一系统凭证抽取完成")
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        log("一系统抽取失败：12 秒内 sessiondata.uid 始终为空")
        return false
    }

    private func tryExtractOnce() async -> Bool {
        // Cookie 先用 native 拿（含 HttpOnly），失败再 fallback 到 JS
        let nativeCookies = await collectNativeCookies()
        CookieJar.shared.mergeNative(nativeCookies)

        let cookieStr = await tryGetCookieString(nativeCookies: nativeCookies)
        guard let cookieStr, !cookieStr.isEmpty else {
            log("  Cookie 仍未就绪")
            return false
        }

        let sessionDataRaw = try? await webView.evaluateJavaScript("localStorage.getItem('sessiondata')")
        guard let sessionData = JSONUtils.normalizeJavaScriptValue(sessionDataRaw),
              sessionData.count > 20 else {
            log("  sessiondata 尚未就绪 (len=\(JSONUtils.normalizeJavaScriptValue(sessionDataRaw)?.count ?? 0))")
            return false
        }
        let uid = JSONUtils.extractTopLevelField(sessionData, field: "uid")
        let aesKey = JSONUtils.extractTopLevelField(sessionData, field: "aesKey")
        let aesIv = JSONUtils.extractTopLevelField(sessionData, field: "aesIv")
        guard let uid, !uid.isEmpty,
              let aesKey, !aesKey.isEmpty,
              let aesIv, !aesIv.isEmpty else {
            log("  sessiondata 缺字段")
            return false
        }

        log("  Cookie/sessiondata/uid/aesKey/aesIv 全部就绪")
        store.set(cookieStr, for: CredentialStore.Keys.tongjiCookies)
        store.set(uid, for: CredentialStore.Keys.tongjiUid)
        store.set(aesKey, for: CredentialStore.Keys.tongjiAesKey)
        store.set(aesIv, for: CredentialStore.Keys.tongjiAesIv)

        if let sessionId = await trySessionId() {
            store.set(sessionId, for: CredentialStore.Keys.tongjiSessionId)
            log("  sessionId(X-Token) 已存储")
        }

        do {
            let studentCode = try StudentCodeCipher.encryptStudentCode(uid: uid, aesKey: aesKey, aesIv: aesIv)
            store.set(studentCode, for: CredentialStore.Keys.tongjiStudentCode)
        } catch {
            log("  studentCode 加密失败: \(error)")
            return false
        }

        // 抓一下用户在表单里填的账号密码（用户内存，由 LoginPage 决定是否落 Keychain）
        await captureFormCredentials()

        // 顺手刷新个人资料（拿不到不阻塞登录完成）
        do {
            _ = try await SessionAPI(store: store).refreshSessionUserOnce()
            log("  个人信息已拉取")
        } catch {
            log("  个人信息拉取失败: \(error.localizedDescription)")
        }

        return true
    }

    private func finishCurrentMode(success: Bool) {
        let mode = currentMode
        if success {
            stage = .finished
        } else {
            stage = .failed("无法获取登录信息，请退出后重试")
        }
        // silent / passwordFill 模式要 resume 等待的 continuation
        if mode != .interactive, let c = silentRenewContinuation {
            silentRenewContinuation = nil
            c.resume(returning: success)
        }
    }

    // MARK: - Cookie 取值（反转优先级）

    private func collectNativeCookies() async -> [HTTPCookie] {
        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return all.filter { $0.domain.lowercased().contains("tongji.edu.cn") }
    }

    private func tryGetCookieString(nativeCookies: [HTTPCookie]) async -> String? {
        // 优先 1：native（含 HttpOnly）
        if !nativeCookies.isEmpty {
            return nativeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        // 优先 2：cookieStore JS API
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
            CookieJar.shared.mergeRawCookieHeader(s, forHost: "1.tongji.edu.cn")
            return s
        }
        // 优先 3：document.cookie
        if let raw = try? await webView.evaluateJavaScript("document.cookie"),
           let s = JSONUtils.normalizeJavaScriptValue(raw), !s.isEmpty {
            CookieJar.shared.mergeRawCookieHeader(s, forHost: "1.tongji.edu.cn")
            return s
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

    private func captureFormCredentials() async {
        if let raw = try? await webView.evaluateJavaScript("window.__capturedUser || ''"),
           let s = JSONUtils.normalizeJavaScriptValue(raw), !s.isEmpty {
            capturedUsername = s
        }
        if let raw = try? await webView.evaluateJavaScript("window.__capturedPass || ''"),
           let s = JSONUtils.normalizeJavaScriptValue(raw), !s.isEmpty {
            capturedPassword = s
        }
    }

    // MARK: - 密码回填 / MFA 检测

    /// 返回 true 表示已经提交了表单；false 表示页面还没准备好。
    private func detectMFAOrFillAndSubmit(username: String, password: String) async throws -> Bool {
        // MFA / 验证码探测
        let mfaProbeJS = """
        (function() {
            try {
                var hasCaptcha = !!document.querySelector('img[id*="captcha" i], img[src*="captcha" i], input[name*="captcha" i], #captcha, .captcha');
                var hasOtp = !!document.querySelector('input[name*="otp" i], input[name*="sms" i], input[name*="code" i][maxlength="6"]');
                var urlHasMfa = /captcha|mfa|otp|second/i.test(location.pathname + location.search);
                return JSON.stringify({ captcha: hasCaptcha, otp: hasOtp, urlMfa: urlHasMfa });
            } catch (e) { return ''; }
        })()
        """
        if let raw = try? await webView.evaluateJavaScript(mfaProbeJS),
           let s = JSONUtils.normalizeJavaScriptValue(raw),
           s.contains("\"captcha\":true") || s.contains("\"otp\":true") || s.contains("\"urlMfa\":true") {
            log("  检测到 MFA / 验证码：\(s)")
            throw AuthError.mfaRequired("学校 SSO 当前要求图形验证码或二次验证，已自动切换为手动登录")
        }

        // 检查输入框存在性
        let probeFormJS = """
        (function() {
            var u = document.querySelector('input[name="j_username"], input[name="username"], input[id="username"]');
            var p = document.querySelector('input[name="j_password"], input[name="password"], input[id="password"]');
            return (u && p) ? '1' : '0';
        })()
        """
        let probeRaw = try? await webView.evaluateJavaScript(probeFormJS)
        let formReady = JSONUtils.normalizeJavaScriptValue(probeRaw) == "1"
        guard formReady else { return false }

        // 注入填表并提交
        let safeUser = escapeForJSString(username)
        let safePwd = escapeForJSString(password)
        let fillJS = """
        (function() {
            function fill(sel, val) {
                var el = document.querySelector(sel);
                if (!el) return false;
                el.focus();
                el.value = val;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            }
            var u = fill('input[name="j_username"]', '\(safeUser)') ||
                    fill('input[name="username"]', '\(safeUser)') ||
                    fill('input[id="username"]', '\(safeUser)');
            var p = fill('input[name="j_password"]', '\(safePwd)') ||
                    fill('input[name="password"]', '\(safePwd)') ||
                    fill('input[id="password"]', '\(safePwd)');
            if (u && p) {
                var btn = document.querySelector('button[type="submit"], input[type="submit"], .submit-btn, .login-btn, button#loginButton');
                if (btn) { btn.click(); return true; }
                var f = document.querySelector('form');
                if (f) { f.submit(); return true; }
            }
            return false;
        })()
        """
        _ = try? await webView.evaluateJavaScript(fillJS)
        log("  已注入密码并提交表单")
        return true
    }

    private func escapeForJSString(_ s: String) -> String {
        // 只 escape 反斜杠和单引号，足够处理 IAM 表单
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "'", with: "\\'")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        return out
    }

    private func maskedUsername(_ s: String) -> String {
        guard s.count > 4 else { return String(repeating: "*", count: s.count) }
        let prefix = s.prefix(2)
        let suffix = s.suffix(2)
        return "\(prefix)***\(suffix)"
    }

    // MARK: - 数据管理

    private func resetState(mode: Mode) {
        currentMode = mode
        hasVisitedSSO = false
        tongjiExtracted = false
        extractionTask?.cancel()
        extractionTask = nil
        if let c = silentRenewContinuation {
            silentRenewContinuation = nil
            c.resume(returning: false)
        }
    }

    private func clearCookies(forDomainSuffix suffix: String) async {
        let dataStore = webView.configuration.websiteDataStore
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let matched = records.filter { $0.displayName.lowercased().hasSuffix(suffix.lowercased()) }
        await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            for: matched
        )
    }

    private func log(_ message: String) {
        let line = "[Auth] \(message)"
        print(line)
        logger.info("\(line, privacy: .public)")
    }
}

extension TongjiAuthCoordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { log("didFinish → \(url.absoluteString)") }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("didFail → \(error.localizedDescription)")
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("didFailProvisional → \(error.localizedDescription)")
    }
}
