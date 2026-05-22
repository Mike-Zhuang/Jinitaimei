import Foundation

@MainActor
public final class CampusNotificationDetector {
    public static let shared = CampusNotificationDetector()

    private let defaults: UserDefaults
    private let notificationManager: LocalNotificationManager
    private let preferenceStore: NotificationPreferenceStore
    private let followStore: StarActivityFollowStore
    private let teachingKnownIdsKey = "notificationKnownTeachingNoticeIds"
    private let starSnapshotKey = "notificationStarActivitySnapshots"

    public init(
        defaults: UserDefaults = .standard,
        notificationManager: LocalNotificationManager = .shared,
        preferenceStore: NotificationPreferenceStore = .shared,
        followStore: StarActivityFollowStore = .shared
    ) {
        self.defaults = defaults
        self.notificationManager = notificationManager
        self.preferenceStore = preferenceStore
        self.followStore = followStore
    }

    public func checkTeachingNoticesIfNeeded() async {
        let preferences = preferenceStore.preferences
        guard preferences.localNotificationsEnabled,
              preferences.teachingNoticeEnabled,
              CampusModel.shared.canCallAPI else {
            return
        }

        do {
            let api = TeachingNoticeAPI()
            let first = try await api.fetchNotices(page: 1)
            var notices = first.notices
            if first.hasMore {
                let second = try await api.fetchNotices(page: 2)
                notices.append(contentsOf: second.notices)
            }
            await processTeachingNotices(notices)
        } catch {
            print("[Notification] 教务通知检测失败: \(error)")
        }
    }

    public func processTeachingNotices(_ notices: [TeachingNotice]) async {
        let preferences = preferenceStore.preferences
        guard preferences.localNotificationsEnabled,
              preferences.teachingNoticeEnabled,
              CampusModel.shared.canCallAPI else {
            return
        }

        let currentIds = Set(notices.map(\.id))
        guard !currentIds.isEmpty else { return }

        let knownIds = Set(defaults.array(forKey: teachingKnownIdsKey) as? [Int] ?? [])
        if knownIds.isEmpty {
            defaults.set(Array(currentIds).sorted(), forKey: teachingKnownIdsKey)
            return
        }

        let newNotices = notices
            .filter { !knownIds.contains($0.id) }
            .sorted { $0.publishDate < $1.publishDate }

        for notice in newNotices {
            await notificationManager.deliver(
                title: "新的教务通知",
                body: notice.title,
                identifier: "teaching-notice-\(notice.id)",
                userInfo: ["type": "teachingNotice", "id": notice.id]
            )
        }

        let merged = Array(knownIds.union(currentIds)).sorted().suffix(200)
        defaults.set(Array(merged), forKey: teachingKnownIdsKey)
    }

    public func processStarActivities(_ activities: [CampusActivity]) async {
        let preferences = preferenceStore.preferences
        guard preferences.localNotificationsEnabled,
              CampusModel.shared.canCallAPI else {
            return
        }

        let currentSnapshots = Dictionary(uniqueKeysWithValues: activities.map {
            ($0.remoteId, StarActivitySnapshot(activity: $0))
        })
        guard !currentSnapshots.isEmpty else { return }

        let oldSnapshots = loadStarSnapshots()
        if oldSnapshots.isEmpty {
            saveStarSnapshots(currentSnapshots)
            return
        }

        for activity in activities {
            let current = StarActivitySnapshot(activity: activity)
            let previous = oldSnapshots[activity.remoteId]

            if previous == nil,
               preferences.starNewActivityEnabled,
               let moduleCode = activity.moduleCode,
               preferences.selectedStarModuleCodes.contains(moduleCode),
               current.status == .notStarted {
                await notificationManager.deliver(
                    title: "新的\(activity.moduleName ?? "卓越星")活动",
                    body: activity.title,
                    identifier: "star-new-\(activity.remoteId)",
                    userInfo: ["type": "starActivityNew", "id": activity.remoteId]
                )
            }

            if preferences.starRegistrationEnabled,
               followStore.followedActivityIds.contains(activity.remoteId),
               previous?.status != .registrationOpen,
               current.status == .registrationOpen {
                await notificationManager.deliver(
                    title: "关注的卓越星活动开始报名",
                    body: activity.title,
                    identifier: "star-registration-\(activity.remoteId)",
                    userInfo: ["type": "starActivityRegistration", "id": activity.remoteId]
                )
            }
        }

        saveStarSnapshots(currentSnapshots)
    }

    public func resetBaselines() {
        defaults.removeObject(forKey: teachingKnownIdsKey)
        defaults.removeObject(forKey: starSnapshotKey)
    }

    private func loadStarSnapshots() -> [Int64: StarActivitySnapshot] {
        guard let data = defaults.data(forKey: starSnapshotKey),
              let snapshots = try? JSONDecoder().decode([StarActivitySnapshot].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: snapshots.map { ($0.remoteId, $0) })
    }

    private func saveStarSnapshots(_ snapshots: [Int64: StarActivitySnapshot]) {
        let ordered = snapshots.values.sorted { $0.remoteId < $1.remoteId }
        if let data = try? JSONEncoder().encode(ordered) {
            defaults.set(data, forKey: starSnapshotKey)
        }
    }
}

private struct StarActivitySnapshot: Codable, Equatable {
    let remoteId: Int64
    let moduleCode: String?
    let title: String
    let status: StarActivityNotificationStatus

    init(activity: CampusActivity) {
        self.remoteId = activity.remoteId
        self.moduleCode = activity.moduleCode
        self.title = activity.title
        self.status = StarActivityNotificationStatus.status(for: activity)
    }
}

private enum StarActivityNotificationStatus: String, Codable {
    case registrationOpen
    case activityOngoing
    case notStarted
    case signInOngoing
    case ended
    case unknown

    static func status(for activity: CampusActivity, now: Date = Date()) -> StarActivityNotificationStatus {
        if let progressName = activity.progressName {
            if progressName.contains("报名") && progressName.contains("进行") { return .registrationOpen }
            if progressName.contains("签到") && progressName.contains("进行") { return .signInOngoing }
            if progressName.contains("活动") && progressName.contains("进行") { return .activityOngoing }
            if progressName.contains("未开始") { return .notStarted }
            if progressName.contains("评价") || progressName.contains("结束") { return .ended }
        }
        if let endDate = activity.activityEndDate, endDate < now {
            return .ended
        }
        if activity.activityDate > now {
            return .notStarted
        }
        return .unknown
    }
}
