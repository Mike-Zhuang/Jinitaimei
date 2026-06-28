import Foundation

/// 本地缓存型校园服务 Store 的最小公共面。
///
/// 这个协议刻意不规定 `sync` 的签名，因为校园卡、图书馆等服务需要 `force`
/// 或分阶段刷新。统一最小面先用于首页刷新编排、错误清理与登出清理，避免为了抽象而破坏已跑通链路。
@MainActor
public protocol CampusLocalStore: AnyObject {
    func loadFromLocal()
    func clearError()
    func clearLocalData()
}
