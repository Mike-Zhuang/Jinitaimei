import Foundation
import SwiftData

/// 校园卡消费流水。
///
/// 交易记录来自同济一卡通接口 `/berserker-search/search/personal/turnover`。
/// 这里保留接口原始语义字段，便于后续继续对齐 DanXi 的展示风格和筛选逻辑。
@Model
public final class CampusCardTransaction {
    public var orderId: String = ""
    public var transactionDateTime: Date = Date.distantPast
    public var amountYuan: Double = 0
    public var balanceYuan: Double = 0
    public var transactionDescription: String = ""
    public var turnoverType: String = ""
    public var locationName: String = ""
    public var payName: String = ""
    public var updatedAt: Date = Date()

    public init(
        orderId: String,
        transactionDateTime: Date,
        amountYuan: Double,
        balanceYuan: Double,
        transactionDescription: String,
        turnoverType: String,
        locationName: String,
        payName: String,
        updatedAt: Date = Date()
    ) {
        self.orderId = orderId
        self.transactionDateTime = transactionDateTime
        self.amountYuan = amountYuan
        self.balanceYuan = balanceYuan
        self.transactionDescription = transactionDescription
        self.turnoverType = turnoverType
        self.locationName = locationName
        self.payName = payName
        self.updatedAt = updatedAt
    }

    /// DanXi 风格的收支方向。
    ///
    /// 同济接口金额本身通常是正数，方向更多体现在 `turnoverType/resume/payName`。
    /// 这里用相对保守的关键词启发式，后续如果拿到更多真实样本再精修。
    public var signedAmountYuan: Double {
        isExpense ? -amountYuan : amountYuan
    }

    public var signSymbol: String {
        signedAmountYuan < 0 ? "-" : "+"
    }

    public var displayLocation: String {
        if !locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !transactionDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transactionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !payName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return payName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "校园卡交易"
    }

    public var detailText: String {
        [transactionDescription, turnoverType, payName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != displayLocation }
            .joined(separator: " · ")
    }

    private var isExpense: Bool {
        let combined = "\(transactionDescription) \(turnoverType) \(payName)".lowercased()
        let expenseKeywords = [
            "消费",
            "扣款",
            "支出",
            "payment",
            "pay",
            "purchase",
            "debit"
        ]
        let incomeKeywords = [
            "充值",
            "补助",
            "退款",
            "退费",
            "返还",
            "入账",
            "credit",
            "refund"
        ]
        if incomeKeywords.contains(where: { combined.contains($0) }) {
            return false
        }
        if expenseKeywords.contains(where: { combined.contains($0) }) {
            return true
        }
        return true
    }
}
