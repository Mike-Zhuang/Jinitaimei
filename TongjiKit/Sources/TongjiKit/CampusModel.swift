import Foundation
import SwiftUI

/// 全局登录态与用户基础信息，对应 DanXi-swift `FudanKit/CampusModel.swift`。
///
/// 通过 `loggedIn` 判定是否完成首次 SSO；`loggedIntoStar` 标识卓越星 Bearer Token 已就绪。
@MainActor
public final class CampusModel: ObservableObject {

    public static let shared = CampusModel()

    @Published public private(set) var loggedIn: Bool = false
    @Published public private(set) var loggedIntoStar: Bool = false
    @Published public private(set) var uid: String?
    @Published public private(set) var profile: TongjiUserProfile?

    private let store: CredentialStore

    public init(store: CredentialStore = .shared) {
        self.store = store
        refresh()
    }

    /// 从 Keychain 同步当前登录态。App 启动 / 登录回调后调用。
    public func refresh() {
        let hasCookie = store.get(CredentialStore.Keys.tongjiCookies) != nil
        let hasUid = store.get(CredentialStore.Keys.tongjiUid) != nil
        self.loggedIn = hasCookie && hasUid
        self.uid = store.get(CredentialStore.Keys.tongjiUid)
        self.profile = TongjiUserProfile.load(from: store)
        self.loggedIntoStar = store.get(CredentialStore.Keys.starBearerToken) != nil
    }

    /// 从一系统刷新个人资料。
    public func refreshProfile() async {
        do {
            profile = try await SessionAPI(store: store).refreshSessionUser()
            refresh()
        } catch {
            refresh()
        }
    }

    /// 退出登录，清空所有凭证。
    public func logout() {
        store.clearAll()
        refresh()
    }
}
