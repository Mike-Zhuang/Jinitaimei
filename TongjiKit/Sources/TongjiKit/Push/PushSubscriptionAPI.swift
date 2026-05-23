import Foundation

public final class PushSubscriptionAPI: Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://tjpush.mikezhuang.cn")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func saveSubscription(
        _ preferences: NotificationPreferences,
        followedActivityIds: Set<Int64>
    ) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/v1/subscriptions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SubscriptionPayload(
                preferences: preferences,
                followedActivityIds: followedActivityIds
            )
        )
        _ = try await send(request)
    }

    public func saveCredentials(email: String, username: String, password: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/v1/subscriptions/credentials"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CredentialPayload(
            email: email,
            tongjiUsername: username,
            tongjiPassword: password
        ))
        _ = try await send(request)
    }

    public func deleteSubscription(email: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/v1/subscriptions"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeletePayload(email: email))
        _ = try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else {
            throw PushSubscriptionError.requestFailed
        }
        return data
    }
}

public enum PushSubscriptionError: LocalizedError {
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "邮件推送服务暂时不可用"
        }
    }
}

private struct SubscriptionPayload: Encodable {
    let email: String
    let mailPushEnabled: Bool
    let teachingNoticeEnabled: Bool
    let starNewActivityEnabled: Bool
    let starRegistrationEnabled: Bool
    let selectedStarModuleCodes: [String]
    let followedStarActivityIds: [Int64]

    init(
        preferences: NotificationPreferences,
        followedActivityIds: Set<Int64>
    ) {
        self.email = preferences.emailRecipient
        self.mailPushEnabled = preferences.mailPushEnabled
        self.teachingNoticeEnabled = preferences.teachingNoticeEnabled
        self.starNewActivityEnabled = preferences.starNewActivityEnabled
        self.starRegistrationEnabled = preferences.starRegistrationEnabled
        self.selectedStarModuleCodes = Array(preferences.selectedStarModuleCodes).sorted()
        self.followedStarActivityIds = Array(followedActivityIds).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case email
        case mailPushEnabled = "mail_push_enabled"
        case teachingNoticeEnabled = "teaching_notice_enabled"
        case starNewActivityEnabled = "star_new_activity_enabled"
        case starRegistrationEnabled = "star_registration_enabled"
        case selectedStarModuleCodes = "selected_star_module_codes"
        case followedStarActivityIds = "followed_star_activity_ids"
    }
}

private struct CredentialPayload: Encodable {
    let email: String
    let tongjiUsername: String
    let tongjiPassword: String

    enum CodingKeys: String, CodingKey {
        case email
        case tongjiUsername = "tongji_username"
        case tongjiPassword = "tongji_password"
    }
}

private struct DeletePayload: Encodable {
    let email: String
}
