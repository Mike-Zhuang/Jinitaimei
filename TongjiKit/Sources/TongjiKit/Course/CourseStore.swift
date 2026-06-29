import Foundation
import SwiftData

/// 课表数据仓储：负责"远端拉取 → 解析 → 替换式入库"全流程。
///
/// 移植自 wish_drom `TongjiScheduleProvider.PersistRawDataAsync` +
/// `ReplaceSchedulesAsync` + `GetAllSchedulesAsync`。
@MainActor
public final class CourseStore: ObservableObject, CampusLocalStore {

    @Published public private(set) var schedules: [CourseSchedule] = []
    @Published public private(set) var terms: [SchoolCalendarTerm] = []
    @Published public private(set) var visibleTerms: [SchoolCalendarTerm] = []
    @Published public private(set) var selectedTerm: SchoolCalendarTerm?
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let api: CourseAPI
    private let context: ModelContext
    private let credentialStore: CredentialStore
    private let selectedCalendarIdKey = "courseSelectedCalendarId"

    public init(
        modelContext: ModelContext,
        api: CourseAPI = CourseAPI(),
        credentialStore: CredentialStore = .shared
    ) {
        self.context = modelContext
        self.api = api
        self.credentialStore = credentialStore
        loadFromLocal()
    }

    /// 启动时从本地数据库加载。
    public func loadFromLocal() {
        do {
            terms = try context.fetch(FetchDescriptor<SchoolCalendarTerm>())
                .sorted { lhs, rhs in
                    let lhsDate = lhs.beginDay ?? .distantPast
                    let rhsDate = rhs.beginDay ?? .distantPast
                    if lhsDate != rhsDate {
                        return lhsDate > rhsDate
                    }
                    return lhs.calendarId > rhs.calendarId
                }
            visibleTerms = resolveVisibleTerms(from: terms)
            let selectableTerms = visibleTerms.isEmpty ? terms : visibleTerms
            selectedTerm = resolveSelectedTerm(from: selectableTerms)
            schedules = try fetchLocalSchedules(for: selectedTerm?.calendarId)
        } catch {
            terms = []
            visibleTerms = []
            selectedTerm = nil
            schedules = []
            lastError = error.localizedDescription
        }
    }

    /// 准备学期列表和当前学期缓存。页面首次进入时调用。
    public func prepare() async {
        loadFromLocal()
        if terms.isEmpty {
            await syncTerms()
        }
        if schedules.isEmpty {
            await sync()
        }
    }

    public func syncTerms() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            let remoteTerms = try await api.fetchCalendarTerms()
            try replaceTerms(remoteTerms)
            try context.save()
            loadFromLocal()
        } catch let err as AuthError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 远端同步：拉当前选中学期课表 → 解析 → 替换该学期旧记录 → 写入新记录。
    public func sync() async {
        if selectedTerm == nil, terms.isEmpty {
            await syncTerms()
        }
        guard let term = selectedTerm ?? resolveSelectedTerm(from: terms) else {
            lastError = "未找到可用学期"
            return
        }
        await sync(calendarId: term.calendarId)
    }

    public func sync(calendarId: Int) async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            let detail = try await api.fetchCalendarDetail(calendarId: calendarId)
            try upsertTerm(detail)
            let raw = try await api.fetchTimetableRaw(calendarId: calendarId)
            let parsed = try CourseScheduleParser.parse(
                rawJSON: raw,
                calendarId: calendarId,
                calendarName: detail.fullName
            )

            // 按学期替换，避免切换学期时覆盖其它学期缓存。
            try clearSchedules(calendarId: calendarId)
            for course in parsed {
                context.insert(course)
            }
            try context.save()
            UserDefaults.standard.set(calendarId, forKey: selectedCalendarIdKey)
            loadFromLocal()
        } catch let err as AuthError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func selectTerm(calendarId: Int) async {
        UserDefaults.standard.set(calendarId, forKey: selectedCalendarIdKey)
        loadFromLocal()
        if schedules.isEmpty {
            await sync(calendarId: calendarId)
        }
    }

    /// 按周筛选。
    public func schedules(forWeek week: Int) -> [CourseSchedule] {
        schedules.filter { $0.weekNumber == week }
    }

    public var selectedCalendarId: Int? {
        selectedTerm?.calendarId
    }

    public var selectedCalendarName: String? {
        selectedTerm?.fullName.nilIfBlank ?? schedules.first?.calendarName.nilIfBlank ?? schedules.first?.semester.nilIfBlank
    }

    public var selectedWeekRange: ClosedRange<Int> {
        if let weekNum = selectedTerm?.weekNum, weekNum > 0 {
            return 1...weekNum
        }
        if let maxWeek = schedules.map(\.weekNumber).max(), maxWeek > 0 {
            return 1...maxWeek
        }
        return 1...1
    }

    public var selectedTermBeginDate: Date? {
        selectedTerm?.beginDay
    }

    public func weekStartDate(for week: Int) -> Date? {
        guard let beginDate = selectedTermBeginDate else { return nil }
        return Calendar(identifier: .gregorian).date(byAdding: .day, value: (week - 1) * 7, to: beginDate)
    }

    public func clearError() {
        lastError = nil
    }

    /// 清空本地课表缓存。退出登录时调用，避免下一个用户看到上一位用户的课表。
    public func clearLocalData() {
        do {
            try clearAllSchedules()
            try clearAllTerms()
            try context.save()
            terms = []
            visibleTerms = []
            selectedTerm = nil
            schedules = []
            lastError = nil
        } catch {
            terms = []
            visibleTerms = []
            selectedTerm = nil
            schedules = []
            lastError = error.localizedDescription
        }
    }

    private func fetchLocalSchedules(for calendarId: Int?) throws -> [CourseSchedule] {
        let descriptor = FetchDescriptor<CourseSchedule>(
            sortBy: [
                SortDescriptor(\.dayOfWeek),
                SortDescriptor(\.startPeriod)
            ]
        )
        let all = try context.fetch(descriptor)
        guard let calendarId else { return all }
        let filtered = all.filter { effectiveCalendarId(for: $0) == calendarId }
        return filtered
    }

    private func resolveSelectedTerm(from terms: [SchoolCalendarTerm]) -> SchoolCalendarTerm? {
        if let storedId = UserDefaults.standard.object(forKey: selectedCalendarIdKey) as? Int,
           let stored = terms.first(where: { $0.calendarId == storedId }) {
            return stored
        }
        if let current = terms.first(where: \.currentTermFlag) {
            return current
        }
        return latestTerm(in: terms)
    }

    private func resolveVisibleTerms(from terms: [SchoolCalendarTerm]) -> [SchoolCalendarTerm] {
        guard !terms.isEmpty else { return [] }
        let admissionYear = inferredAdmissionYear()
        let upperTerm = terms.first(where: \.nextTermFlag) ?? terms.first(where: \.currentTermFlag)

        let filtered = terms.filter { term in
            if let admissionYear,
               let academicYear = academicStartYear(for: term),
               academicYear < admissionYear {
                return false
            }
            guard let upperTerm else { return true }
            return isTerm(term, notLaterThan: upperTerm)
        }

        return filtered.sorted { lhs, rhs in
            let lhsDate = lhs.beginDay ?? .distantFuture
            let rhsDate = rhs.beginDay ?? .distantFuture
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.calendarId < rhs.calendarId
        }
    }

    private func inferredAdmissionYear() -> Int? {
        if let grade = credentialStore.get(CredentialStore.Keys.tongjiGrade),
           let year = firstFourDigitYear(in: grade) {
            return year
        }
        guard let uid = credentialStore.get(CredentialStore.Keys.tongjiUid)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              uid.count >= 2 else {
            return nil
        }
        let prefix = String(uid.prefix(2))
        guard let shortYear = Int(prefix) else { return nil }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let currentShortYear = currentYear % 100
        if shortYear <= currentShortYear + 1 {
            return 2000 + shortYear
        }
        return 1900 + shortYear
    }

    private func firstFourDigitYear(in text: String) -> Int? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 4 else { return nil }
        for index in 0...(scalars.count - 4) {
            let slice = scalars[index..<(index + 4)]
            guard slice.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) else {
                continue
            }
            let value = String(String.UnicodeScalarView(slice))
            if let year = Int(value), (1900...2100).contains(year) {
                return year
            }
        }
        return nil
    }

    private func academicStartYear(for term: SchoolCalendarTerm) -> Int? {
        if let year = firstFourDigitYear(in: term.fullName) {
            return year
        }
        guard let beginDay = term.beginDay else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: beginDay)
        let month = calendar.component(.month, from: beginDay)
        return month >= 7 ? year : year - 1
    }

    private func isTerm(_ term: SchoolCalendarTerm, notLaterThan upperTerm: SchoolCalendarTerm) -> Bool {
        if let beginDay = term.beginDay, let upperBeginDay = upperTerm.beginDay {
            return beginDay <= upperBeginDay
        }
        return term.calendarId <= upperTerm.calendarId
    }

    private func latestTerm(in terms: [SchoolCalendarTerm]) -> SchoolCalendarTerm? {
        terms.max { lhs, rhs in
            let lhsDate = lhs.beginDay ?? .distantPast
            let rhsDate = rhs.beginDay ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.calendarId < rhs.calendarId
        }
    }

    private func replaceTerms(_ remoteTerms: [SchoolCalendarTermInfo]) throws {
        let now = Date()
        let existingTerms = try context.fetch(FetchDescriptor<SchoolCalendarTerm>())
        let existingById = Dictionary(uniqueKeysWithValues: existingTerms.map { ($0.calendarId, $0) })
        let remoteIds = Set(remoteTerms.map(\.calendarId))

        for term in existingTerms where !remoteIds.contains(term.calendarId) {
            context.delete(term)
        }

        for info in remoteTerms {
            if let existing = existingById[info.calendarId] {
                existing.fullName = info.fullName
                existing.beginDay = info.beginDay
                existing.endDay = info.endDay
                existing.weekNum = info.weekNum
                existing.currentTermFlag = info.currentTermFlag
                existing.nextTermFlag = info.nextTermFlag
                existing.syncTime = now
            } else {
                context.insert(
                    SchoolCalendarTerm(
                        calendarId: info.calendarId,
                        fullName: info.fullName,
                        beginDay: info.beginDay,
                        endDay: info.endDay,
                        weekNum: info.weekNum,
                        currentTermFlag: info.currentTermFlag,
                        nextTermFlag: info.nextTermFlag,
                        syncTime: now
                    )
                )
            }
        }
    }

    private func upsertTerm(_ info: SchoolCalendarTermInfo) throws {
        let all = try context.fetch(FetchDescriptor<SchoolCalendarTerm>())
        if let existing = all.first(where: { $0.calendarId == info.calendarId }) {
            existing.fullName = info.fullName
            existing.beginDay = info.beginDay
            existing.endDay = info.endDay
            existing.weekNum = info.weekNum
            existing.currentTermFlag = info.currentTermFlag || existing.currentTermFlag
            existing.nextTermFlag = info.nextTermFlag || existing.nextTermFlag
            existing.syncTime = Date()
        } else {
            context.insert(
                SchoolCalendarTerm(
                    calendarId: info.calendarId,
                    fullName: info.fullName,
                    beginDay: info.beginDay,
                    endDay: info.endDay,
                    weekNum: info.weekNum,
                    currentTermFlag: info.currentTermFlag,
                    nextTermFlag: info.nextTermFlag
                )
            )
        }
    }

    private func clearSchedules(calendarId: Int) throws {
        let descriptor = FetchDescriptor<CourseSchedule>()
        for course in try context.fetch(descriptor) where effectiveCalendarId(for: course) == calendarId {
            context.delete(course)
        }
    }

    private func clearAllSchedules() throws {
        for course in try context.fetch(FetchDescriptor<CourseSchedule>()) {
            context.delete(course)
        }
    }

    private func clearAllTerms() throws {
        for term in try context.fetch(FetchDescriptor<SchoolCalendarTerm>()) {
            context.delete(term)
        }
    }

    /// 旧课表记录没有 `calendarId`，读取时把它们归到当前选中/当前学期，避免迁移后“空白”。
    private func effectiveCalendarId(for course: CourseSchedule) -> Int {
        if course.calendarId > 0 { return course.calendarId }
        if let current = terms.first(where: \.currentTermFlag)?.calendarId { return current }
        if let selected = selectedTerm?.calendarId { return selected }
        return 0
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
