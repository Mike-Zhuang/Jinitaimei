import Foundation
import SwiftData

/// 课表数据仓储：负责"远端拉取 → 解析 → 替换式入库"全流程。
///
/// 移植自 wish_drom `TongjiScheduleProvider.PersistRawDataAsync` +
/// `ReplaceSchedulesAsync` + `GetAllSchedulesAsync`。
@MainActor
public final class CourseStore: ObservableObject, CampusLocalStore {

    @Published public private(set) var schedules: [CourseSchedule] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let api: CourseAPI
    private let context: ModelContext

    public init(modelContext: ModelContext, api: CourseAPI = CourseAPI()) {
        self.context = modelContext
        self.api = api
        loadFromLocal()
    }

    /// 启动时从本地数据库加载。
    public func loadFromLocal() {
        let descriptor = FetchDescriptor<CourseSchedule>(
            sortBy: [
                SortDescriptor(\.dayOfWeek),
                SortDescriptor(\.startPeriod)
            ]
        )
        do {
            schedules = try context.fetch(descriptor)
        } catch {
            schedules = []
            lastError = error.localizedDescription
        }
    }

    /// 远端同步：拉课表 → 解析 → 清空旧记录 → 写入新记录。
    public func sync() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            let raw = try await api.fetchTimetableRaw()
            let parsed = try CourseScheduleParser.parse(rawJSON: raw)

            // 替换式更新
            try clearAll()
            for course in parsed {
                context.insert(course)
            }
            try context.save()
            loadFromLocal()
        } catch let err as AuthError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 按周筛选。
    public func schedules(forWeek week: Int) -> [CourseSchedule] {
        schedules.filter { $0.weekNumber == week }
    }

    public func clearError() {
        lastError = nil
    }

    /// 清空本地课表缓存。退出登录时调用，避免下一个用户看到上一位用户的课表。
    public func clearLocalData() {
        do {
            try clearAll()
            try context.save()
            schedules = []
            lastError = nil
        } catch {
            schedules = []
            lastError = error.localizedDescription
        }
    }

    private func clearAll() throws {
        let descriptor = FetchDescriptor<CourseSchedule>()
        let all = try context.fetch(descriptor)
        for course in all {
            context.delete(course)
        }
    }
}
