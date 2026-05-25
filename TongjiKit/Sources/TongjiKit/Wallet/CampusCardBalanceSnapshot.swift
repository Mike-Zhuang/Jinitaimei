import Foundation
import SwiftData

/// 校园卡余额快照。
///
/// 当前学校接口只稳定提供“当前余额”，没有可靠的历史流水接口；
/// 因此我们在本地按时间持续记录余额快照，用于后续页面折线图和低余额提醒判定。
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
