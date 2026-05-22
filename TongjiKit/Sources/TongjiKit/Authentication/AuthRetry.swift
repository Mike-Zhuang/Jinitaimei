import Foundation

/// 通用 401/403 重试 wrapper：执行 `body` 一次，如果抛 `AuthError.expired`
/// 就调用 `AuthRecoveryManager.shared.renewIfPossible()` 续期一次，再重试 `body`。
///
/// **绝不无限循环**：续期失败直接重抛原错误，由上层（UI）决定提示交互登录。
///
/// 注意：从 `TongjiAuthCoordinator.attemptSilentRenew` 内部调用业务 API 时，
/// 必须走对应 `_*Once()` 私版方法，避免重新进入 `AuthRecoveryManager` 形成
/// "等自己 finish"的死锁（`single-flight` 会把第二次调用挂在第一个 Task 的
/// 同一个 `await` 上）。
public func withAuthRetry<T: Sendable>(
    _ body: @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch let error as AuthError where error.isExpired {
        let renewed = await AuthRecoveryManager.shared.renewIfPossible()
        guard renewed else { throw error }
        return try await body()
    }
}

/// STAR 平台专用 401/403 重试 wrapper。
/// STAR 与一系统是两套独立鉴权，互不影响。
public func withStarAuthRetry<T: Sendable>(
    _ body: @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch let error as AuthError where error.isExpired {
        let renewed = await StarAuthCoordinator.shared.renewIfPossible()
        guard renewed else { throw error }
        return try await body()
    }
}
