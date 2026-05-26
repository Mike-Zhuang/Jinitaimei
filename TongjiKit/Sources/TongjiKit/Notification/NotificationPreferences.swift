import Foundation

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var localNotificationsEnabled: Bool
    public var mailPushEnabled: Bool
    public var teachingNoticeEnabled: Bool
    public var starNewActivityEnabled: Bool
    public var starRegistrationEnabled: Bool
    public var campusCardLowBalanceEnabled: Bool
    public var campusCardLowBalanceThreshold: Double
    public var selectedStarModuleCodes: Set<String>
    public var emailRecipient: String

    public init(
        localNotificationsEnabled: Bool = false,
        mailPushEnabled: Bool = false,
        teachingNoticeEnabled: Bool = true,
        starNewActivityEnabled: Bool = true,
        starRegistrationEnabled: Bool = true,
        campusCardLowBalanceEnabled: Bool = false,
        campusCardLowBalanceThreshold: Double = 50,
        selectedStarModuleCodes: Set<String> = Self.defaultStarModuleCodes,
        emailRecipient: String = ""
    ) {
        self.localNotificationsEnabled = localNotificationsEnabled
        self.mailPushEnabled = mailPushEnabled
        self.teachingNoticeEnabled = teachingNoticeEnabled
        self.starNewActivityEnabled = starNewActivityEnabled
        self.starRegistrationEnabled = starRegistrationEnabled
        self.campusCardLowBalanceEnabled = campusCardLowBalanceEnabled
        self.campusCardLowBalanceThreshold = campusCardLowBalanceThreshold
        self.selectedStarModuleCodes = selectedStarModuleCodes
        self.emailRecipient = emailRecipient
    }

    public static let defaultStarModuleCodes: Set<String> = [
        "hongwen",
        "mingde",
        "shizhi",
        "qiusuo",
        "lixing"
    ]

    private enum CodingKeys: String, CodingKey {
        case localNotificationsEnabled
        case mailPushEnabled
        case teachingNoticeEnabled
        case starNewActivityEnabled
        case starRegistrationEnabled
        case campusCardLowBalanceEnabled
        case campusCardLowBalanceThreshold
        case selectedStarModuleCodes
        case emailRecipient
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.localNotificationsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .localNotificationsEnabled
        ) ?? false
        self.mailPushEnabled = try container.decodeIfPresent(Bool.self, forKey: .mailPushEnabled) ?? false
        self.teachingNoticeEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .teachingNoticeEnabled
        ) ?? true
        self.starNewActivityEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .starNewActivityEnabled
        ) ?? true
        self.starRegistrationEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .starRegistrationEnabled
        ) ?? true
        self.campusCardLowBalanceEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .campusCardLowBalanceEnabled
        ) ?? false
        self.campusCardLowBalanceThreshold = try container.decodeIfPresent(
            Double.self,
            forKey: .campusCardLowBalanceThreshold
        ) ?? 50
        self.selectedStarModuleCodes = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .selectedStarModuleCodes
        ) ?? Self.defaultStarModuleCodes
        self.emailRecipient = try container.decodeIfPresent(String.self, forKey: .emailRecipient) ?? ""
    }
}

@MainActor
public final class NotificationPreferenceStore: ObservableObject {
    public static let shared = NotificationPreferenceStore()

    @Published public private(set) var preferences: NotificationPreferences

    private let defaults: UserDefaults
    private let key = "notificationPreferences"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.load(from: defaults, key: key)
    }

    public func update(_ transform: (inout NotificationPreferences) -> Void) {
        var next = preferences
        transform(&next)
        preferences = next
        save()
    }

    public func refresh() {
        preferences = Self.load(from: defaults, key: key)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> NotificationPreferences {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(NotificationPreferences.self, from: data) else {
            return NotificationPreferences()
        }
        return value
    }
}
