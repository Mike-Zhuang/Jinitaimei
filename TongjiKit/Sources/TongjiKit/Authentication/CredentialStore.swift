import Foundation
import Security
import LocalAuthentication

/// 基于 Keychain 的安全凭证存储。
///
/// 对应 wish_drom 中的 `ISecureDataStorage`。所有同济一系统 (`tongji_*`)
/// 与卓越星 (`star_*`) 凭证统一通过此类读写，避免散落到 UserDefaults。
///
/// 自动登录所需的账号密码使用 `kSecAttrAccessControl(biometryCurrentSet)`
/// 单独保护：写入与读取都强制 Face ID / Touch ID 校验，密钥锁进 Secure Enclave，
/// 用户更换生物识别（如重新录脸）后旧条目自动失效。
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

    // MARK: - 生物识别保护下的自动登录凭证

    public struct AutoLoginCredentials: Sendable {
        public let user: String
        public let password: String
    }

    /// 写入自动登录账号密码（Face ID / Touch ID 保护）。
    public func saveAutoLoginCredentials(user: String, password: String) throws {
        try writeBiometryProtected(value: user, for: Keys.autoLoginUser)
        do {
            try writeBiometryProtected(value: password, for: Keys.autoLoginPassword)
        } catch {
            // 密码写失败时把刚才写的用户名也清掉，避免一半状态。
            remove(Keys.autoLoginUser)
            throw error
        }
    }

    /// 读取自动登录账号密码。会触发 Face ID / Touch ID 提示（reason 由调用方提供）。
    /// 返回 `nil` 表示用户未开启自动登录或验证失败。
    public func loadAutoLoginCredentials(reason: String) async -> AutoLoginCredentials? {
        async let userTask = readBiometryProtected(key: Keys.autoLoginUser, reason: reason)
        async let pwdTask = readBiometryProtected(key: Keys.autoLoginPassword, reason: reason)
        let user = await userTask
        let pwd = await pwdTask
        guard let user, !user.isEmpty, let pwd, !pwd.isEmpty else { return nil }
        return AutoLoginCredentials(user: user, password: pwd)
    }

    /// 不读 value、不触发 Face ID 弹窗，仅检查 Keychain 中是否存在自动登录条目。
    public func hasAutoLoginCredentials() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Keys.autoLoginUser,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed 说明条目存在但需要交互校验
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func removeAutoLoginCredentials() {
        remove(Keys.autoLoginUser)
        remove(Keys.autoLoginPassword)
    }

    private func writeBiometryProtected(value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw NSError(domain: "CredentialStore", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法编码为 UTF-8"])
        }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            throw accessError!.takeRetainedValue() as Error
        }

        // 先删旧值
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ] as CFDictionary)

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain 写入失败 (\(status))"]
            )
        }
    }

    private func readBiometryProtected(key: String, reason: String) async -> String? {
        let serviceCopy = service
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = reason
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceCopy,
                    kSecAttrAccount as String: key,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationContext as String: context
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecSuccess, let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - 业务键名常量

    public enum Keys {
        // 一系统（1.tongji.edu.cn）相关
        /// 旧版扁平字符串 cookie；迁移完成后由 `tongjiCookiesJar` 接管，但保留为兜底读取。
        public static let tongjiCookies = "tongji_cookies"
        /// 结构化 cookie jar（JSON）。
        public static let tongjiCookiesJar = "tongji_cookies_jar"
        public static let tongjiSessionId = "tongji_session_id"
        public static let tongjiStudentCode = "tongji_student_code"
        public static let tongjiCalendarId = "tongji_calendar_id"
        public static let tongjiCalendarBeginDayMs = "tongji_calendar_begin_day_ms"
        public static let tongjiCalendarEndDayMs = "tongji_calendar_end_day_ms"
        public static let tongjiCalendarWeekNum = "tongji_calendar_week_num"
        public static let tongjiCalendarCurrentWeek = "tongji_calendar_current_week"
        public static let tongjiCalendarSimpleName = "tongji_calendar_simple_name"
        public static let tongjiTeachingWeekStart = "tongji_teaching_week_start"
        public static let tongjiTeachingWeekEnd = "tongji_teaching_week_end"
        public static let tongjiExamWeekStart = "tongji_exam_week_start"
        public static let tongjiExamWeekEnd = "tongji_exam_week_end"
        public static let tongjiAesKey = "tongji_aes_key"
        public static let tongjiAesIv = "tongji_aes_iv"
        public static let tongjiUid = "tongji_uid"
        public static let tongjiUserName = "tongji_user_name"
        public static let tongjiFacultyName = "tongji_faculty_name"
        public static let tongjiDeptOrMajor = "tongji_dept_or_major"
        public static let tongjiGrade = "tongji_grade"
        public static let tongjiLoginTime = "tongji_login_time"
        public static let tongjiLastLoginTime = "tongji_last_login_time"
        public static let tongjiUserSexCode = "tongji_user_sex_code"
        public static let tongjiUserTypeCode = "tongji_user_type_code"
        public static let tongjiInnerRoles = "tongji_inner_roles"
        public static let tongjiPhotoPath = "tongji_photo_path"

        // 自动登录凭证（生物识别保护）
        public static let autoLoginUser = "auto_login_user"
        public static let autoLoginPassword = "auto_login_password"

        // 卓越星（star.tongji.edu.cn）相关
        public static let starBearerToken = "star_bearer_token"
        public static let starScoreSummary = "star_score_summary"
    }
}
