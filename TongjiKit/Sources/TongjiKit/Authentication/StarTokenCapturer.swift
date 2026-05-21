import Foundation
@preconcurrency import WebKit
import os.log

/// 后台静默抓取卓越星 (STAR) 平台的 Bearer Token。
///
/// 设计：登录页只负责一系统 SSO，关闭后由本类挂一个**不可见**的 WKWebView 在
/// 主视图层级里（0×0 frame），自动加载 STAR H5 入口，复用浏览器进程的 SSO cookie
/// 让 STAR 完成 OAuth → 注入 XHR 拦截器抓 Authorization 头。
///
/// 之所以一定要挂在 view hierarchy 里：`WKWebView` 不在 view 树上时，渲染进程会被
/// 系统冻结，`evaluateJavaScript` 不会执行，URL navigation 也不会真的触发请求。
///
/// 移植自 wish_drom `StarActivityProvider.TryGetTokenViaInterceptionAsync`。
@MainActor
public final class StarTokenCapturer: NSObject, ObservableObject {

    public enum Stage: Equatable {
        case idle
        case loading
        case capturing
        case finished
        case failed(String)
    }

    @Published public private(set) var stage: Stage = .idle

    public let webView: WKWebView
    private let store: CredentialStore
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "StarAuth")

    /// STAR H5 应用入口。直接进 host 根会被重定向到 `/admin` 管理后台，
    /// 必须显式打 `/app/` 才能拿到 H5 SPA。
    private let starLandingURL = URL(string: "https://star.tongji.edu.cn/app/")!

    /// 手机版 UA：让 STAR 服务端把我们识别为 H5 客户端而不是桌面浏览器。
    private let mobileUA = "Mozilla/5.0 (Linux; Android 14; SM-S918U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    private var captureTask: Task<Void, Never>?
    private var urlObservation: NSKeyValueObservation?
    private var injected = false

    public init(store: CredentialStore = .shared) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Mobile"
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.customUserAgent = mobileUA
        self.webView.navigationDelegate = self
        self.webView.isHidden = true

        self.urlObservation = self.webView.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let self, let url = change.newValue ?? nil else { return }
            Task { @MainActor in
                self.log("URL 变更 → \(url.absoluteString)")
            }
        }
    }

    deinit {
        urlObservation?.invalidate()
    }

    /// 启动后台抓取。已有缓存 token 时直接返回成功。
    public func startIfNeeded() {
        if store.get(CredentialStore.Keys.starBearerToken) != nil {
            log("已有缓存 Bearer Token，跳过后台抓取")
            stage = .finished
            return
        }
        guard captureTask == nil else { return }
        log("启动后台 STAR Bearer Token 抓取")
        stage = .loading
        injected = false
        webView.load(URLRequest(url: starLandingURL))

        captureTask = Task { @MainActor in
            await runCapture()
            self.captureTask = nil
        }
    }

    private func runCapture() async {
        // 等页面初始 bootstrap
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        await injectInterceptor()
        injected = true
        stage = .capturing

        // 触发一次活动列表请求来钓出 Bearer Token
        await triggerUniRequest()

        // 轮询拦截到的 token，最多 15 秒
        for attempt in 0..<15 {
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
        log("STAR Token 抓取超时（15 秒），稍后用户进入卓越星 Tab 时可手动重试")
        stage = .failed("卓越星初始化超时")
    }

    private func injectInterceptor() async {
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
        log("XHR 拦截器已注入")
    }

    private func triggerUniRequest() async {
        let uniAvail = try? await webView.evaluateJavaScript(
            "typeof uni!=='undefined'&&uni.request?1:0"
        )
        if JSONUtils.normalizeJavaScriptValue(uniAvail) == "1" {
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
            log("uni.request 已触发")
        }
        _ = try? await webView.evaluateJavaScript(
            "location.hash='__probe__'+Date.now()"
        )
    }

    private func stripBearerPrefix(_ token: String) -> String {
        if token.lowercased().hasPrefix("bearer ") {
            return String(token.dropFirst(7))
        }
        return token
    }

    private func log(_ message: String) {
        let line = "[StarAuth] \(message)"
        print(line)
        logger.info("\(line, privacy: .public)")
    }
}

extension StarTokenCapturer: WKNavigationDelegate {
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
