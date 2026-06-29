import Foundation
import SwiftUI

/// 登录态五段式：
///
/// - `loggedOut`：从未登录或已主动退出。本地数据应被清空。
/// - `valid`：服务端会话有效，可正常调 API。
/// - `renewing`：API 刚遇 401，正在跑 `AuthRecoveryManager.renewIfPossible()`，
///    UI 显示非阻塞 banner，本地缓存继续展示。
/// - `expiredRecoverable`：scenePhase 检查或前置请求确认已过期但**未确定是否能恢复**，
///    等同 `renewing` 的视觉，但还没启动续期任务。
/// - `requiresInteractiveLogin`：L1+L2 都失败，必须用户手动重登。
///    本地缓存**仍然不清**，避免"打开就空白"，由用户点 banner 上的"去登录"决定。
///
/// 仅 `logout()` 会真正清空本地数据。
public enum CampusAuthState: Equatable, Sendable {
    case loggedOut
    case valid
    case renewing
    case expiredRecoverable
    case requiresInteractiveLogin
}

/// 全局登录态与用户基础信息，对应 DanXi-swift `FudanKit/CampusModel.swift`。
@MainActor
public final class CampusModel: ObservableObject {

    public static let shared = CampusModel()

    @Published public private(set) var authState: CampusAuthState = .loggedOut
    @Published public private(set) var loggedIntoStar: Bool = false
    @Published public private(set) var uid: String?
    @Published public private(set) var profile: TongjiUserProfile?
    @Published public private(set) var starScoreSummary: StarScoreSummary?

    /// 兼容 `if campusModel.loggedIn` 这种历史写法。
    /// 包含除 `loggedOut` 外的所有状态：哪怕需要交互重登，也算"有本地账户"，
    /// UI 应继续展示本地缓存并通过 banner 引导用户。
    public var loggedIn: Bool {
        authState != .loggedOut
    }

    /// 严格意义的"会话可用"：仅 `.valid`。仅供必须确认服务端可访问的场景使用。
    public var canCallAPI: Bool {
        authState == .valid
    }

    /// UI 决定是否显示"会话刷新中"非阻塞 banner。
    public var isRefreshingAuth: Bool {
        authState == .renewing || authState == .expiredRecoverable
    }

    /// UI 决定是否显示"请重新登录"banner / 按钮。
    public var requiresInteractiveLogin: Bool {
        authState == .requiresInteractiveLogin
    }

    private let store: CredentialStore
    private var lastSessionCheckAt: Date?
    private let sessionCheckThrottle: TimeInterval = 600  // 10 分钟

    public init(store: CredentialStore = .shared) {
        self.store = store
        refresh()
    }

    /// 从 Keychain 同步当前登录态。App 启动 / 登录回调后调用。
    /// 当本地有完整凭证时进入 `.valid`；否则 `.loggedOut`。
    /// **不会覆盖 `renewing` / `requiresInteractiveLogin` 等中间态。**
    public func refresh() {
        let hasCookie = CookieJar.shared.hasAnyTongjiCookie() ||
                        (store.get(CredentialStore.Keys.tongjiCookies)?.isEmpty == false)
        let hasUid = store.get(CredentialStore.Keys.tongjiUid)?.isEmpty == false
        let credsPresent = hasCookie && hasUid

        if credsPresent {
            if authState == .loggedOut {
                authState = .valid
            }
            // 已经在 valid / renewing / expiredRecoverable / requires：不动
        } else {
            if authState != .loggedOut { authState = .loggedOut }
        }

        self.uid = store.get(CredentialStore.Keys.tongjiUid)
        self.profile = TongjiUserProfile.load(from: store)
        self.loggedIntoStar = store.get(CredentialStore.Keys.starBearerToken) != nil
        self.starScoreSummary = StarScoreSummary.load(from: store)
    }

    // MARK: - 状态推进接口（由 AuthRecoveryManager / API wrapper 调用）

    public func markValid() {
        if authState != .valid { authState = .valid }
        lastSessionCheckAt = Date()
    }

    public func markRenewing() {
        // 只在已登录的前提下转 renewing
        guard loggedIn else { return }
        if authState != .renewing { authState = .renewing }
    }

    public func markRecoverableExpired() {
        guard loggedIn else { return }
        if authState != .expiredRecoverable { authState = .expiredRecoverable }
    }

    public func markRequiresInteractiveLogin() {
        if authState != .requiresInteractiveLogin {
            authState = .requiresInteractiveLogin
        }
    }

    /// 从一系统刷新个人资料。失败仅记录，不直接登出。
    public func refreshProfile() async {
        do {
            profile = try await SessionAPI(store: store).refreshSessionUser()
            refresh()
        } catch {
            refresh()
        }
    }

    /// 从 STAR 平台刷新个人星值。失败时保留已有缓存状态。
    public func refreshStarScoreSummary() async {
        do {
            starScoreSummary = try await ActivityAPI(store: store).fetchStarScoreSummary()
            refresh()
        } catch {
            refresh()
        }
    }

    // MARK: - scenePhase 节流会话检查

    /// 回前台时由 RootView 调用。节流 10 分钟一次；失败转 `expiredRecoverable`
    /// 并触发静默续期；**不直接登出**。
    public func performScenePhaseCheckIfDue() {
        guard loggedIn else { return }
        if let last = lastSessionCheckAt,
           Date().timeIntervalSince(last) < sessionCheckThrottle {
            return
        }
        lastSessionCheckAt = Date()

        Task { @MainActor in
            do {
                await AuthRecoveryManager.shared.silentCoordinator.restoreStoredTongjiCookiesToWebView()
                _ = try await SessionAPI(store: store).refreshSessionUserOnce()
                markValid()
                if !CookieJar.shared.hasCookie(forHost: "all.tongji.edu.cn") {
                    await AuthRecoveryManager.shared.silentCoordinator.warmUpAllTongjiSSOIfNeeded()
                }
            } catch let error as AuthError where error.isExpired {
                markRecoverableExpired()
                _ = await AuthRecoveryManager.shared.renewIfPossible()
            } catch {
                // 网络抖动等不改状态
            }
        }
    }

    /// 退出登录，清空所有凭证。
    public func logout() {
        store.clearAll()
        CookieJar.shared.clear()
        store.removeAutoLoginCredentials()
        CampusNotificationDetector.shared.resetBaselines()
        refresh()
    }
}
