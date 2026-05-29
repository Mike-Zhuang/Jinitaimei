import Foundation
import os.log

public struct CampusCardBalancePayload: Equatable, Sendable {
    public let balanceYuan: Double
    public let account: String
    public let ownerName: String
    public let cardIdentifier: String
    public let capturedAt: Date

    public init(
        balanceYuan: Double,
        account: String,
        ownerName: String,
        cardIdentifier: String,
        capturedAt: Date = Date()
    ) {
        self.balanceYuan = balanceYuan
        self.account = account
        self.ownerName = ownerName
        self.cardIdentifier = cardIdentifier
        self.capturedAt = capturedAt
    }
}

public struct CampusCardTransactionPayload: Equatable, Sendable {
    public let orderId: String
    public let transactionDateTime: Date
    public let amountYuan: Double
    public let balanceYuan: Double
    public let transactionDescription: String
    public let turnoverType: String
    public let locationName: String
    public let payName: String
    public let updatedAt: Date

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
}

public enum YikatongTransactionFetchMode: Sendable {
    case quick
    case full

    var maxPages: Int {
        switch self {
        case .quick:
            1
        case .full:
            7
        }
    }
}

/// 同济校园卡（一卡通）API。
///
/// 协议移植自 `wish_drom/Services/DataProviders/YikatongBalanceProvider.cs`：
/// 请求 `queryCard` 时优先同时带上校园卡 Cookie 和 `synjones-auth` Bearer Token。
/// 真机上校园卡 H5 有时只下发 Bearer Token，因此 Cookie 缺失时先尝试 token-only，
/// 若接口返回 401/403 再触发续期。
public final class YikatongAPI {
    private let apiBase = URL(string: "https://pay-yikatong.tongji.edu.cn")!
    private let balancePath = "/berserker-app/ykt/tsm/queryCard?synAccessSource=h5"
    private let transactionsPath = "/berserker-search/search/personal/turnover?size=8&current=%d&synAccessSource=h5"
    private let store: CredentialStore
    private let session: URLSession
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "YikatongAPI")

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func fetchBalance() async throws -> CampusCardBalancePayload {
        try await withYikatongAuthRetry { [self] in
            try await fetchBalanceOnce()
        }
    }

    public func fetchTransactions(maxPages: Int = 7) async throws -> [CampusCardTransactionPayload] {
        try await withYikatongAuthRetry { [self] in
            try await fetchTransactionsOnce(maxPages: maxPages)
        }
    }

    public func fetchBalanceOnce() async throws -> CampusCardBalancePayload {
        guard let token = currentBearerToken(), !token.isEmpty else {
            throw AuthError.expired("未找到校园卡访问令牌")
        }
        let cookie = currentCookieHeader()

        let url = URL(string: "\(apiBase.absoluteString)\(balancePath)")!
        var request = URLRequest(url: url)
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue("bearer \(token)", forHTTPHeaderField: "synjones-auth")
        request.setValue("h5", forHTTPHeaderField: "synaccesssource")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15
        log("请求校园卡余额 API，cookie=\(cookie?.isEmpty == false)")

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response)

        let payload = try JSONDecoder().decode(YikatongBalanceResponse.self, from: data)
        guard payload.success, let firstCard = payload.data?.card.first else {
            throw AuthError.loginFlowFailed(payload.msg?.isEmpty == false ? payload.msg! : "校园卡余额响应异常")
        }

        return CampusCardBalancePayload(
            balanceYuan: Double(firstCard.elecAccamt) / 100,
            account: firstCard.account ?? "",
            ownerName: firstCard.name ?? "",
            cardIdentifier: firstCard.cardNameEn ?? ""
        )
    }

    public func fetchTransactionsOnce(maxPages: Int = 7) async throws -> [CampusCardTransactionPayload] {
        guard let token = currentBearerToken(), !token.isEmpty else {
            throw AuthError.expired("未找到校园卡访问令牌")
        }
        let cookie = currentCookieHeader()

        var allTransactions: [CampusCardTransactionPayload] = []
        var seenOrderIds = Set<String>()

        for page in 1...maxPages {
            let path = String(format: transactionsPath, page)
            let url = URL(string: "\(apiBase.absoluteString)\(path)")!
            var request = URLRequest(url: url)
            if let cookie, !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            request.setValue("bearer \(token)", forHTTPHeaderField: "synjones-auth")
            request.setValue("h5", forHTTPHeaderField: "synaccesssource")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.timeoutInterval = 15

            log("请求校园卡消费记录第 \(page) 页")
            let (data, response) = try await session.data(for: request)
            try ensureAuth(response: response)

            let payload = try JSONDecoder().decode(YikatongTransactionsResponse.self, from: data)
            if payload.success == false {
                throw AuthError.loginFlowFailed(payload.msg?.isEmpty == false ? payload.msg! : "校园卡消费记录响应异常")
            }
            let records = payload.data?.records ?? []
            Self.logTransactionDebugInfo(records: records, page: page)
            if records.isEmpty {
                log("校园卡消费记录第 \(page) 页无数据，停止翻页")
                break
            }

            var pageNewCount = 0
            for record in records {
                guard !record.orderId.isEmpty, !seenOrderIds.contains(record.orderId) else { continue }
                seenOrderIds.insert(record.orderId)
                allTransactions.append(record.payload)
                pageNewCount += 1
            }

            log("校园卡消费记录第 \(page) 页新增 \(pageNewCount) 条，累计 \(allTransactions.count) 条")
            if pageNewCount == 0 {
                break
            }
        }

        return allTransactions.sorted { $0.transactionDateTime > $1.transactionDateTime }
    }

    private func currentCookieHeader() -> String? {
        store.get(CredentialStore.Keys.yikatongCookies)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentBearerToken() -> String? {
        store.get(CredentialStore.Keys.yikatongBearerToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearStoredCredentials() {
        store.remove(CredentialStore.Keys.yikatongBearerToken)
        store.remove(CredentialStore.Keys.yikatongCookies)
        log("校园卡旧 Token/Cookie 已清理，准备重新续期")
    }

    private func ensureAuth(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AuthError.expired("校园卡凭证已失效")
        }
        if !(200..<300).contains(http.statusCode) {
            throw AuthError.loginFlowFailed("HTTP \(http.statusCode)")
        }
    }

    private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        print("[YikatongAPI] \(message)")
    }

    private static var didLogTransactionDebugInfo = false

    private static func logTransactionDebugInfo(records: [YikatongTransactionRecord], page: Int) {
        #if DEBUG
        guard !didLogTransactionDebugInfo, page == 1, let first = records.first else { return }
        didLogTransactionDebugInfo = true
        let dateHints = first.debugDateCandidates
            .map { "\($0.key)=\($0.value.isEmpty ? "empty" : "present")" }
            .joined(separator: ",")
        print("[YikatongAPI] 消费记录字段诊断：keys=\(first.debugKeys.joined(separator: ",")); dateHints=\(dateHints)")
        #endif
    }
}

private struct YikatongBalanceResponse: Decodable {
    let success: Bool
    let msg: String?
    let data: YikatongBalanceData?
}

private struct YikatongBalanceData: Decodable {
    let card: [YikatongCard]
}

private struct YikatongCard: Decodable {
    let elecAccamt: Int64
    let account: String?
    let name: String?
    let cardNameEn: String?

    enum CodingKeys: String, CodingKey {
        case elecAccamt = "elec_accamt"
        case account
        case name
        case cardNameEn = "card_name_en"
    }
}

private struct YikatongTransactionsResponse: Decodable {
    let success: Bool?
    let msg: String?
    let data: YikatongTransactionsData?
}

private struct YikatongTransactionsData: Decodable {
    let records: [YikatongTransactionRecord]
}

private struct YikatongTransactionRecord: Decodable {
    let orderId: String
    let transactionDateTimeRaw: String?
    let tranamt: Int64?
    let cardBalance: Int64?
    let resume: String?
    let turnoverType: String?
    let locationName: String?
    let payName: String?
    let debugKeys: [String]
    let debugDateCandidates: [(key: String, value: String)]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        debugKeys = container.allKeys.map(\.stringValue).sorted()
        orderId = Self.stringValue(for: ["orderId", "order_id", "orderno", "orderNo", "id"], in: container) ?? UUID().uuidString
        transactionDateTimeRaw = Self.stringValue(
            for: [
                "jndatetimeStr", "effectdateStr", "jndatetime", "effectdate",
                "jnDateTime", "jn_datetime", "datetime", "dateTime",
                "tranTime", "transTime", "tradeTime", "createTime", "createdTime",
                "operationTime", "time", "payTime"
            ],
            in: container
        )
        tranamt = Self.int64Value(for: ["tranamt", "tranAmt", "amount", "money", "transAmt"], in: container)
        cardBalance = Self.int64Value(for: ["cardBalance", "card_balance", "balance", "remain", "remainAmt"], in: container)
        resume = Self.stringValue(for: ["resume", "summary", "description", "remark", "transName"], in: container)
        turnoverType = Self.stringValue(for: ["turnoverType", "turnover_type", "type", "transType"], in: container)
        locationName = Self.stringValue(for: ["locationName", "location_name", "location", "place", "devphyid"], in: container)
        payName = Self.stringValue(for: ["payName", "pay_name", "merchant", "shopName", "businessName"], in: container)
        debugDateCandidates = [
            "jndatetimeStr", "effectdateStr", "jndatetime", "effectdate",
            "jnDateTime", "datetime", "tranTime", "transTime",
            "tradeTime", "createTime", "operationTime", "time", "payTime"
        ].map { key in
            (key, Self.stringValue(for: [key], in: container) ?? "")
        }
    }

    var payload: CampusCardTransactionPayload {
        CampusCardTransactionPayload(
            orderId: orderId,
            transactionDateTime: Self.parseDate(transactionDateTimeRaw),
            amountYuan: Double(tranamt ?? 0) / 100,
            balanceYuan: Double(cardBalance ?? 0) / 100,
            transactionDescription: resume ?? "",
            turnoverType: turnoverType ?? "",
            locationName: locationName ?? "",
            payName: payName ?? ""
        )
    }

    private static func parseDate(_ raw: String?) -> Date {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .distantPast }
        if let interval = TimeInterval(raw) {
            let seconds = interval > 10_000_000_000 ? interval / 1000 : interval
            return Date(timeIntervalSince1970: seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyy年M月d日 HH:mm:ss",
            "yyyy年M月d日 HH:mm",
            "yyyy年M月d日",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyyMMddHHmmss",
            "yyyy-MM-dd HH:mm"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: raw) ?? .distantPast
    }

    private static func stringValue(for keys: [String], in container: KeyedDecodingContainer<DynamicCodingKey>) -> String? {
        for key in keys {
            let codingKey = DynamicCodingKey(stringValue: key)
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey), !value.isEmpty {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: codingKey) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                return String(value)
            }
        }
        return nil
    }

    private static func int64Value(for keys: [String], in container: KeyedDecodingContainer<DynamicCodingKey>) -> Int64? {
        for key in keys {
            let codingKey = DynamicCodingKey(stringValue: key)
            if let value = try? container.decodeIfPresent(Int64.self, forKey: codingKey) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                return Int64(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
               let amount = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return amount
            }
        }
        return nil
    }
}

private func withYikatongAuthRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch let error as AuthError where error.isExpired {
        YikatongAPI().clearStoredCredentials()
        let renewed = await YikatongAuthCoordinator.shared.renewIfPossible()
        guard renewed else { throw error }
        return try await operation()
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
