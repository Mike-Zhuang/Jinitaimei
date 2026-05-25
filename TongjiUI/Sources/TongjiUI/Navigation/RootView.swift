import SwiftUI
import SwiftData
import WebKit
import TongjiKit

/// App 根视图：日程、校园与设置三个 Tab。
///
/// 同时把 `AuthRecoveryManager.shared.silentCoordinator.webView` 作为
/// 0×0 隐藏视图挂在 RootView 上：这样静默续期 / 密码回填 WKWebView 才能
/// 稳定执行 SPA JS（off-screen webview 容易被系统暂停）。
public struct RootView: View {

    @StateObject private var campusModel = CampusModel.shared
    @StateObject private var loginPresenter = LoginPresentationModel.shared
    @Environment(\.scenePhase) private var scenePhase

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

                SettingsPage()
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                    }
            }

            // 0×0 隐藏 WebView：让静默续期能稳定执行 SPA JS。
            HiddenWebViewHost(webView: AuthRecoveryManager.shared.silentCoordinator.webView)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // STAR 续期也依赖 WebView 跑 OAuth 跳转 / XHR 拦截，同样需要挂在视图树上。
            HiddenWebViewHost(webView: StarAuthCoordinator.shared.webView)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            HiddenWebViewHost(webView: YikatongAuthCoordinator.shared.webView)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task {
            campusModel.refresh()
        }
        .fullScreenCover(isPresented: $loginPresenter.isPresented) {
            LoginPage {
                loginPresenter.dismiss()
                campusModel.refresh()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                campusModel.performScenePhaseCheckIfDue()
                Task {
                    await LocalNotificationManager.shared.refreshAuthorizationStatus()
                    await CampusNotificationDetector.shared.checkTeachingNoticesIfNeeded()
                }
            }
        }
    }
}

private struct CoursePageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        CoursePage(modelContext: modelContext)
    }
}

/// 把 `WKWebView` 嵌进视图树但不占面积，专供续期协调器使用。
private struct HiddenWebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
