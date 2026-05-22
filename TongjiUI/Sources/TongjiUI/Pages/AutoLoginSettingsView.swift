import SwiftUI
import LocalAuthentication
import TongjiKit

/// 自动登录设置页。
///
/// 严格 opt-in：
/// - 默认关闭。
/// - 开启时弹 sheet 收集账号密码，**只本地存到 Secure Enclave**，
///   不向任何服务器发送。
/// - 写入前后均触发 Face ID / Touch ID 校验。
/// - 关闭时立即从 Keychain 移除条目。
/// - 学校启用图形验证码 / 短信码时，自动登录会被检测到并降级为手动登录。
public struct AutoLoginSettingsView: View {

    @State private var isEnabled: Bool
    @State private var showCredentialSheet = false
    @State private var showBiometryUnavailable = false
    @State private var lastErrorMessage: String?

    public init() {
        _isEnabled = State(initialValue: CredentialStore.shared.hasAutoLoginCredentials())
    }

    public var body: some View {
        Form {
            Section {
                Toggle("启用自动登录", isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in
                        if newValue {
                            guard biometryAvailable() else {
                                showBiometryUnavailable = true
                                return
                            }
                            showCredentialSheet = true
                        } else {
                            CredentialStore.shared.removeAutoLoginCredentials()
                            isEnabled = false
                        }
                    }
                ))
            } footer: {
                Text("密码仅保存在本机 Secure Enclave，由 Face ID / Touch ID 保护，绝不会上传到任何服务器。学校如启用短信 / 图形验证码 / 二次验证，会自动降级为手动登录。")
            }

            if isEnabled {
                Section {
                    Button("重新输入账号密码") {
                        showCredentialSheet = true
                    }
                    Button(role: .destructive) {
                        CredentialStore.shared.removeAutoLoginCredentials()
                        isEnabled = false
                    } label: {
                        Text("移除已保存的账号密码")
                    }
                }
            }

            if let lastErrorMessage {
                Section {
                    Text(lastErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("自动登录")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCredentialSheet) {
            CredentialCaptureSheet { user, password in
                do {
                    try CredentialStore.shared.saveAutoLoginCredentials(user: user, password: password)
                    isEnabled = true
                    lastErrorMessage = nil
                } catch {
                    isEnabled = CredentialStore.shared.hasAutoLoginCredentials()
                    lastErrorMessage = "保存失败：\(error.localizedDescription)"
                }
            }
        }
        .alert("设备不支持生物识别", isPresented: $showBiometryUnavailable) {
            Button("好") {}
        } message: {
            Text("Face ID / Touch ID 不可用时，无法启用自动登录。请到系统设置中开启生物识别。")
        }
    }

    private func biometryAvailable() -> Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
}

private struct CredentialCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var password = ""
    let onSave: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("学号", text: $user)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("统一身份认证密码", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("提交前会弹出 Face ID / Touch ID 校验，校验通过后才会写入 Keychain。")
                }
            }
            .navigationTitle("保存账号密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(user.trimmingCharacters(in: .whitespaces),
                               password)
                        dismiss()
                    }
                    .disabled(user.isEmpty || password.isEmpty)
                }
            }
        }
    }
}
