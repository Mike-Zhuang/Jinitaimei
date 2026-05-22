import Foundation
import os.log

/// 一系统登录态恢复总入口。
///
/// 设计：所有业务 API（CourseAPI / TeachingNoticeAPI / SessionAPI 等）
/// 在 401/403 时统一通过 `withAuthRetry` 调到这里，本类负责按层级尝试：
///
/// 1. **L1 静默续期**：复用现有 IAM cookie，让隐藏 WKWebView 重访 `1.tongji.edu.cn/workbench`，
///    如果 IAM SSO 没过期会自动跳回 workbench → 重新抽出 sessiondata / cookie。
/// 2. **L2 密码自动回填**：用户在设置里开启了"保存密码"并通过 Face ID 后，
///    用 Keychain 取出账号密码注入 IAM 登录表单提交。**遇到验证码 / MFA 直接放弃，
///    降级到 L3。**
/// 3. **L3 交互登录**：上述全部失败 → 标记 `requiresInteractiveLogin`，UI 提示用户。
///
/// **Single-flight**：多个 API 并发失败时只跑一次续期，其他调用 await 同一个 Task。
@MainActor
public final class AuthRecoveryManager {

    public static let shared = AuthRecoveryManager()

    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "AuthRecovery")
    private var renewTask: Task<Bool, Never>?

    /// 共享的隐藏续期协调器：必须挂在 RootView 视图树上才能稳定执行 SPA JS。
    /// 由 `RootView` 在初始化时挂载 `silentCoordinator.webView`。
    public let silentCoordinator = TongjiAuthCoordinator()

    public init() {}

    public func renewIfPossible() async -> Bool {
        if let task = renewTask {
            log("已有续期任务在跑，复用结果")
            return await task.value
        }

        CampusModel.shared.markRenewing()
        let task = Task<Bool, Never> { @MainActor in
            // L1：静默续期
            log("L1 启动静默续期")
            if await silentCoordinator.attemptSilentRenew() {
                log("L1 静默续期成功")
                CampusModel.shared.markValid()
                return true
            }
            log("L1 静默续期失败")

            // L2：密码自动回填（仅在用户开启了自动登录时）
            if CredentialStore.shared.hasAutoLoginCredentials() {
                log("L2 检测到自动登录凭证，触发 Face ID 解锁后回填")
                if let creds = await CredentialStore.shared.loadAutoLoginCredentials(
                    reason: "自动登录同济校园账户"
                ) {
                    do {
                        let ok = try await silentCoordinator.attemptPasswordRelogin(
                            username: creds.user, password: creds.password
                        )
                        if ok {
                            log("L2 密码回填登录成功")
                            CampusModel.shared.markValid()
                            return true
                        }
                    } catch AuthError.mfaRequired {
                        log("L2 遇到 MFA / 验证码，降级到交互登录")
                    } catch {
                        log("L2 密码回填失败: \(error.localizedDescription)")
                    }
                } else {
                    log("L2 Face ID 解锁失败或被取消")
                }
            } else {
                log("L2 用户未开启自动登录，跳过")
            }

            // L3：标记需要交互登录，由 UI 决定弹登录页时机
            CampusModel.shared.markRequiresInteractiveLogin()
            return false
        }
        renewTask = task
        let result = await task.value
        renewTask = nil
        return result
    }

    private func log(_ message: String) {
        let line = "[AuthRecovery] \(message)"
        print(line)
        logger.info("\(line, privacy: .public)")
    }
}
