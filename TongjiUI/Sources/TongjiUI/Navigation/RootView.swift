import SwiftUI
import SwiftData
import WebKit
import TongjiKit

/// App 根视图：两个 Tab + 未登录拦截 + 后台 STAR Token 抓取。
///
/// 登录页只完成一系统 SSO；登录成功关闭登录页后，本视图会挂一个不可见的
/// `StarTokenCapturer.webView`（0×0）在视图层级里，让 WebKit 在后台自动跑完
/// STAR 的 OAuth 流程，抓出 Bearer Token。用户感知不到。
public struct RootView: View {

    @StateObject private var campusModel = CampusModel.shared
    @StateObject private var starCapturer = StarTokenCapturer()
    @State private var showLogin = false

    public init() {}

    public var body: some View {
        ZStack {
            TabView {
                CoursePageContainer()
                    .tabItem {
                        Label("日程", systemImage: "calendar")
                    }

                CampusHome()
                    .tabItem {
                        Label("校园", systemImage: "building.columns")
                    }
            }

            // 隐藏的后台 WebView：用于静默抓取 STAR Bearer Token
            HiddenWebViewHost(webView: starCapturer.webView)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .task {
            campusModel.refresh()
            if !campusModel.loggedIn {
                showLogin = true
            } else {
                starCapturer.startIfNeeded()
            }
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginPage(onFinished: {
                showLogin = false
                campusModel.refresh()
                starCapturer.startIfNeeded()
            })
        }
    }
}

private struct CoursePageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        CoursePage(modelContext: modelContext)
    }
}

/// 把一个外部传入的 `WKWebView` 挂到 SwiftUI 视图树上但**不可见也不可点**。
/// WKWebView 只有进入 view hierarchy 才会被 WebKit 当作前台页面正常渲染/执行 JS。
private struct HiddenWebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.isHidden = true
        webView.isUserInteractionEnabled = false
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
