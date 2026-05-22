import SwiftUI
import WebKit
import LocalAuthentication
import TongjiKit

/// 同济统一身份认证（SSO）登录页。只负责一系统登录。
/// 卓越星活动列表使用公开接口，无需额外鉴权。
///
/// 登录完成后，如果用户在表单里输入的账号密码被 JS capture 到了，
/// 并且当前没有开启自动登录，会弹一次"是否保存以便自动续期登录"的 prompt。
public struct LoginPage: View {

    @StateObject private var coordinator = TongjiAuthCoordinator()
    @Environment(\.dismiss) private var dismiss
    @State private var didStart = false
    @State private var showSaveCredentialsPrompt = false
    @State private var pendingUser = ""
    @State private var pendingPassword = ""
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
                    if coordinator.isExtracting {
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
                coordinator.startFreshInteractiveLogin()
            }
            .onChange(of: coordinator.stage) { _, newValue in
                if case .finished = newValue {
                    CampusModel.shared.markValid()
                    CampusModel.shared.refresh()
                    let user = coordinator.capturedUsername
                    let pwd = coordinator.capturedPassword
                    if biometryAvailable(),
                       !user.isEmpty, !pwd.isEmpty,
                       !CredentialStore.shared.hasAutoLoginCredentials() {
                        pendingUser = user
                        pendingPassword = pwd
                        showSaveCredentialsPrompt = true
                    } else {
                        onFinished()
                        dismiss()
                    }
                }
            }
            .alert("保存账号密码以自动续期？", isPresented: $showSaveCredentialsPrompt) {
                Button("保存") {
                    do {
                        try CredentialStore.shared.saveAutoLoginCredentials(
                            user: pendingUser, password: pendingPassword
                        )
                    } catch {
                        // 保存失败不阻塞登录流程
                    }
                    pendingUser = ""; pendingPassword = ""
                    onFinished()
                    dismiss()
                }
                Button("不用，谢谢", role: .cancel) {
                    pendingUser = ""; pendingPassword = ""
                    onFinished()
                    dismiss()
                }
            } message: {
                Text("保存后，会话过期时 App 可在后台用 Face ID / Touch ID 解锁并自动登录，无需你手动重新输入。账号密码仅保存在本机 Secure Enclave。可随时在 设置 → 自动登录 中关闭。")
            }
        }
    }

    private func biometryAvailable() -> Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
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
            Color(.systemBackground)
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

private extension TongjiAuthCoordinator {
    var isExtracting: Bool {
        if case .extractingTongji = stage { return true }
        return false
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
