import Foundation
import Security

/// 基于 Keychain 的安全凭证存储。
///
/// 对应 wish_drom 中的 `ISecureDataStorage`。所有同济一系统 (`tongji_*`)
/// 与卓越星 (`star_*`) 凭证统一通过此类读写，避免散落到 UserDefaults。
public final class CredentialStore: @unchecked Sendable {

    public static let shared = CredentialStore(service: "com.jinitaimei.credentials")

    private let service: String

    public init(service: String) {
        self.service = service
    }

    // MARK: - 通用 KV 读写

    public func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 清空当前 service 下的所有键值。
    public func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 业务键名常量

    public enum Keys {
        // 一系统（1.tongji.edu.cn）相关
        public static let tongjiCookies = "tongji_cookies"
        public static let tongjiSessionId = "tongji_session_id"
        public static let tongjiStudentCode = "tongji_student_code"
        public static let tongjiCalendarId = "tongji_calendar_id"
        public static let tongjiCalendarBeginDayMs = "tongji_calendar_begin_day_ms"
        public static let tongjiTeachingWeekStart = "tongji_teaching_week_start"
        public static let tongjiTeachingWeekEnd = "tongji_teaching_week_end"
        public static let tongjiAesKey = "tongji_aes_key"
        public static let tongjiAesIv = "tongji_aes_iv"
        public static let tongjiUid = "tongji_uid"

        // 卓越星（star.tongji.edu.cn）相关
        public static let starBearerToken = "star_bearer_token"
    }
}
