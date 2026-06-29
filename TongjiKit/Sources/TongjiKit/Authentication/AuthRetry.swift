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

/// 图书馆空间预约系统专用 401/403 重试 wrapper。
/// 该系统使用独立 JWT，和一系统 / STAR / 校园卡互不污染。
public func withLibrarySpaceAuthRetry<T: Sendable>(
    _ body: @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch let error as AuthError where error.isExpired || error.isMissingLibraryToken {
        await LibrarySpaceAuthCoordinator.shared.clearToken()
        let renewed = await LibrarySpaceAuthCoordinator.shared.renewIfPossible()
        guard renewed else { throw error }
        return try await body()
    }
}

/// 智能控水专用重试 wrapper。
/// 水控依赖一卡通 `synjones-auth` 派生出的 KS 登录态和独立 AES 参数；
/// 失效时只重跑水控鉴权，不污染一系统 / STAR / 图书馆状态。
public func withWaterControlAuthRetry<T: Sendable>(
    _ body: @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch let error as AuthError where error.isExpired || error.isMissingWaterControlParams {
        let renewed = await WaterAuthCoordinator.shared.renewIfPossible(force: true)
        guard renewed else { throw error }
        return try await body()
    }
}

private extension AuthError {
    var isMissingLibraryToken: Bool {
        if case .notLoggedIn = self { return true }
        return false
    }

    var isMissingWaterControlParams: Bool {
        if case .notLoggedIn = self { return true }
        return false
    }
}
