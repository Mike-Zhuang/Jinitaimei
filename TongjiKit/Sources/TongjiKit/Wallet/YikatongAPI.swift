import Foundation

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

/// 同济校园卡（一卡通）API。
///
/// 协议移植自 `wish_drom/Services/DataProviders/YikatongBalanceProvider.cs`：
/// 请求 `queryCard` 时必须同时带上 `JWTUser/TGC` Cookie 和 `synjones-auth` Bearer Token。
public final class YikatongAPI {
    private let apiBase = URL(string: "https://pay-yikatong.tongji.edu.cn")!
    private let balancePath = "/berserker-app/ykt/tsm/queryCard?synAccessSource=h5"
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func fetchBalance() async throws -> CampusCardBalancePayload {
        try await withYikatongAuthRetry { [self] in
            try await fetchBalanceOnce()
        }
    }

    public func fetchBalanceOnce() async throws -> CampusCardBalancePayload {
        guard let cookie = currentCookieHeader(), !cookie.isEmpty else {
            throw AuthError.expired("未找到校园卡登录凭证")
        }
        guard let token = currentBearerToken(), !token.isEmpty else {
            throw AuthError.expired("未找到校园卡访问令牌")
        }

        let url = URL(string: "\(apiBase.absoluteString)\(balancePath)")!
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("bearer \(token)", forHTTPHeaderField: "synjones-auth")
        request.setValue("h5", forHTTPHeaderField: "synaccesssource")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15

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

    private func currentCookieHeader() -> String? {
        store.get(CredentialStore.Keys.yikatongCookies)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentBearerToken() -> String? {
        store.get(CredentialStore.Keys.yikatongBearerToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private func withYikatongAuthRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch let error as AuthError where error.isExpired {
        let renewed = await YikatongAuthCoordinator.shared.renewIfPossible()
        guard renewed else { throw error }
        return try await operation()
    }
}
