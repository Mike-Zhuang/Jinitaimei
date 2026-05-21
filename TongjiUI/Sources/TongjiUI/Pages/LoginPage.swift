import SwiftUI
import WebKit
import TongjiKit

/// 同济统一身份认证（SSO）登录页。只负责一系统登录。
/// 卓越星活动列表使用公开接口，无需额外鉴权。
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
                ZStack {
                    WebViewContainer(webView: coordinator.webView)
                    if case .extractingTongji = coordinator.stage {
                        loadingOverlay
                    }
                }
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
                Text("登录成功，正在保存身份信息…")
            case .extractingStar:
                ProgressView()
                Text("正在同步卓越星信息…")
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

    /// 抽取阶段把 WebView 盖住，避免用户看见 SPA 在乱跳。
    private var loadingOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.95)
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                Text("登录成功，正在保存身份信息…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
