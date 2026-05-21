import SwiftUI
import WebKit
import TongjiKit

/// 同济统一身份认证（SSO）登录页。
///
/// 将 `TongjiAuthCoordinator` 持有的 `WKWebView` 直接展示给用户，
/// 用户完成登录后协调器自动完成两阶段凭证抓取。
public struct LoginPage: View {

    @StateObject private var coordinator = TongjiAuthCoordinator()
    @Environment(\.dismiss) private var dismiss
    @State private var didStart = false
    private let onFinished: () -> Void

    public init(onFinished: @escaping () -> Void = {}) {
        self.onFinished = onFinished
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                WebViewContainer(webView: coordinator.webView)
                    .edgesIgnoringSafeArea(.bottom)
            }
            .navigationTitle("同济统一身份认证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                guard !didStart else { return }
                didStart = true
                coordinator.start()
            }
            .onChange(of: coordinator.stage) { _, newValue in
                if case .finished = newValue {
                    CampusModel.shared.refresh()
                    onFinished()
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 8) {
            switch coordinator.stage {
            case .idle, .awaitingUserLogin:
                Image(systemName: "person.crop.circle")
                Text("请用学号 + 统一身份密码登录")
            case .extractingTongji:
                ProgressView()
                Text("登录成功，正在初始化课表…")
            case .capturingStarToken:
                ProgressView()
                Text("正在初始化卓越星…")
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("准备完成")
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(msg)
            }
            Spacer()
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}

/// 包装 `WKWebView` 给 SwiftUI 使用。区别于通用做法：这里直接用协调器已创建的实例，
/// 避免登录态/processPool 与协调器内部不一致。
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
