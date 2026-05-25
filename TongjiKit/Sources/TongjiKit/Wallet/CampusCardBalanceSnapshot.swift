import Foundation
import SwiftData

/// 校园卡余额快照。
///
/// 余额快照仍然有价值：
/// - 低余额提醒要基于“上一次余额状态”做跨阈值判断
/// - 余额接口和消费流水接口是分开的，余额快照可以作为更轻量的本地缓存
/// - 即便流水同步失败，也不影响余额本身的展示与提醒
@Model
public final class CampusCardBalanceSnapshot {
    public var capturedAt: Date = Date()
    public var balanceYuan: Double = 0
    public var account: String = ""
    public var ownerName: String = ""
    public var cardIdentifier: String = ""

    public init(
        capturedAt: Date,
        balanceYuan: Double,
        account: String,
        ownerName: String,
        cardIdentifier: String
    ) {
        self.capturedAt = capturedAt
        self.balanceYuan = balanceYuan
        self.account = account
        self.ownerName = ownerName
        self.cardIdentifier = cardIdentifier
    }
}
