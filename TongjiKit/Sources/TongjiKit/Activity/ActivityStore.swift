import Foundation
import SwiftData

/// 卓越星活动仓储：拉取 → 解析 → 替换式入库。
@MainActor
public final class ActivityStore: ObservableObject, CampusLocalStore {

    @Published public private(set) var activities: [CampusActivity] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let api: ActivityAPI
    private let context: ModelContext

    public init(modelContext: ModelContext, api: ActivityAPI = ActivityAPI()) {
        self.context = modelContext
        self.api = api
        loadFromLocal()
    }

    public func loadFromLocal() {
        let descriptor = FetchDescriptor<CampusActivity>(
            sortBy: [SortDescriptor(\.activityDate, order: .reverse)]
        )
        do {
            activities = try context.fetch(descriptor)
        } catch {
            activities = []
            lastError = error.localizedDescription
        }
    }

    public func sync() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            let rawList = try await api.fetchAllActivitiesRaw()
            let parsed = ActivityParser.parse(rawJSONStrings: rawList)
            try clearAll()
            for item in parsed {
                context.insert(item)
            }
            try context.save()
            loadFromLocal()
            await CampusNotificationDetector.shared.processStarActivities(activities)
        } catch let err as AuthError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func clearError() {
        lastError = nil
    }

    /// 清空本地活动缓存。虽然活动列表来自公开接口，但退出登录后不展示校园服务内容。
    public func clearLocalData() {
        do {
            try clearAll()
            try context.save()
            activities = []
            lastError = nil
        } catch {
            activities = []
            lastError = error.localizedDescription
        }
    }

    private func clearAll() throws {
        let descriptor = FetchDescriptor<CampusActivity>()
        let all = try context.fetch(descriptor)
        for item in all { context.delete(item) }
    }
}
