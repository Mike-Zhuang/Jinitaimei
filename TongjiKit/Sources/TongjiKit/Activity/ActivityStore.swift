import Foundation
import SwiftData

/// 卓越星活动仓储：拉取 → 解析 → 替换式入库。
@MainActor
public final class ActivityStore: ObservableObject, CampusLocalStore {

    @Published public private(set) var activities: [CampusActivity] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var hasMore = true
    @Published public private(set) var lastError: String?

    private let api: ActivityAPI
    private let context: ModelContext
    private let pageSize = 20
    private var currentPage = 0

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
        await refreshFirstPage()
    }

    public func refreshFirstPage() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            let page = try await api.fetchActivitiesPage(pageNo: 1, pageSize: pageSize)
            let parsed = ActivityParser.parse(rawJSONStrings: page.items)
            try clearAll()
            for item in parsed {
                context.insert(item)
            }
            try context.save()
            currentPage = 1
            hasMore = page.hasMore
            loadFromLocal()
            await syncAllForNotification(maxPages: 3)
        } catch let err as AuthError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        lastError = nil
        do {
            let nextPage = max(1, currentPage + 1)
            let page = try await api.fetchActivitiesPage(pageNo: nextPage, pageSize: pageSize)
            let parsed = ActivityParser.parse(rawJSONStrings: page.items)
            try upsert(parsed)
            try context.save()
            currentPage = nextPage
            hasMore = page.hasMore
            loadFromLocal()
        } catch let err as AuthError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func syncAllForNotification(maxPages: Int) async {
        do {
            let rawList = try await api.fetchAllActivitiesRaw(maxPages: maxPages)
            let parsed = ActivityParser.parse(rawJSONStrings: rawList)
            await CampusNotificationDetector.shared.processStarActivities(parsed)
        } catch let err as AuthError {
            lastError = err.errorDescription
        } catch {
            print("[StarActivity] 通知检测分页同步失败: \(error)")
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
            currentPage = 0
            hasMore = true
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

    private func upsert(_ incoming: [CampusActivity]) throws {
        let existing = try context.fetch(FetchDescriptor<CampusActivity>())
        var byRemoteId = Dictionary(uniqueKeysWithValues: existing.map { ($0.remoteId, $0) })
        for item in incoming {
            if let current = byRemoteId[item.remoteId] {
                current.title = item.title
                current.source = item.source
                current.activityDate = item.activityDate
                current.activityEndDate = item.activityEndDate
                current.location = item.location
                current.link = item.link
                current.descriptionText = item.descriptionText
                current.progressValue = item.progressValue
                current.progressName = item.progressName
                current.moduleCode = item.moduleCode
                current.moduleName = item.moduleName
                current.starPoints = item.starPoints
                current.syncTime = item.syncTime
            } else {
                context.insert(item)
                byRemoteId[item.remoteId] = item
            }
        }
    }
}
