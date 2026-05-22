import Foundation

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var localNotificationsEnabled: Bool
    public var teachingNoticeEnabled: Bool
    public var starNewActivityEnabled: Bool
    public var starRegistrationEnabled: Bool
    public var selectedStarModuleCodes: Set<String>
    public var emailRecipient: String

    public init(
        localNotificationsEnabled: Bool = false,
        teachingNoticeEnabled: Bool = true,
        starNewActivityEnabled: Bool = true,
        starRegistrationEnabled: Bool = true,
        selectedStarModuleCodes: Set<String> = Self.defaultStarModuleCodes,
        emailRecipient: String = ""
    ) {
        self.localNotificationsEnabled = localNotificationsEnabled
        self.teachingNoticeEnabled = teachingNoticeEnabled
        self.starNewActivityEnabled = starNewActivityEnabled
        self.starRegistrationEnabled = starRegistrationEnabled
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
