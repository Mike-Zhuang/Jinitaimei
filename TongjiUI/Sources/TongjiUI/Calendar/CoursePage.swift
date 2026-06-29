import SwiftUI
import SwiftData
import TongjiKit
import EventKit

/// 日程 Tab 主页：按周展示同济课表。
///
/// 排版参考 DanXi-swift `FudanUI/Pages/CoursePage.swift`：
/// - 标题"日程"（inline）+ 右上角菜单
/// - List 形态：第一个 Section 放周次 Stepper（第 N 周 - +）
/// - 第二个 Section 放周视图（节次时间侧栏 + 7 列日期 + 课程块）
public struct CoursePage: View {

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var store: CourseStore
    @StateObject private var examStore: ExamScheduleStore
    @State private var selectedWeek: Int = 1
    @State private var showError = false
    @State private var showExportSheet = false
    @State private var showCalendarPermissionAlert = false
    @State private var selectedExam: ExamScheduleItem?

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: CourseStore(modelContext: modelContext))
        _examStore = StateObject(wrappedValue: ExamScheduleStore(modelContext: modelContext))
    }

    public var body: some View {
        NavigationStack {
            List {
                if campusModel.isRefreshingAuth || campusModel.requiresInteractiveLogin {
                    AuthStateBanner()
                }
                if store.schedules.isEmpty && examStore.scheduledExams.isEmpty && !store.isLoading && !examStore.isLoading {
                    emptyState
                } else {
                    if !store.visibleTerms.isEmpty {
                        Section {
                            Picker("学期", selection: Binding(
                                get: { store.selectedCalendarId ?? 0 },
                                set: { newValue in
                                    Task {
                                        await store.selectTerm(calendarId: newValue)
                                        computeCurrentWeek()
                                    }
                                }
                            )) {
                                ForEach(store.visibleTerms) { term in
                                    Text(term.fullName)
                                        .tag(term.calendarId)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    Section {
                        Stepper(value: $selectedWeek, in: weekRange) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("第 \(selectedWeek) 周")
                                if let semesterName {
                                    Text(semesterName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section {
                        WeekGridView(
                            courses: store.schedules(forWeek: selectedWeek),
                            exams: examsForSelectedWeek,
                            weekStartDate: weekStartDate(for: selectedWeek)
                        )
                        .listRowInsets(EdgeInsets())
                    }

                    if !examsForSelectedWeek.isEmpty {
                        Section("本周考试") {
                            ForEach(examsForSelectedWeek) { exam in
                                Button {
                                    selectedExam = exam
                                } label: {
                                    CoursePageExamRow(exam: exam)
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task {
                                await store.sync()
                                await examStore.sync()
                                store.loadFromLocal()
                                examStore.loadFromLocal()
                                computeCurrentWeek()
                            }
                        } label: {
                            Label("刷新课表与考试", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isLoading || examStore.isLoading || !campusModel.loggedIn)

                        Button {
                            Task { await requestCalendarAccess() }
                        } label: {
                            Label("导出到日历", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.schedules.isEmpty || semesterBeginDate() == nil)
                    } label: {
                        if store.isLoading || examStore.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showExportSheet) {
                if let beginDate = semesterBeginDate() {
                    CourseExportSheet(
                        schedules: store.schedules,
                        exams: currentTermScheduledExams,
                        semesterStart: beginDate
                    )
                }
            }
            .sheet(item: $selectedExam) { exam in
                CoursePageExamDetailSheet(exam: exam)
                    .presentationDetents([.medium, .large])
            }
            .refreshable {
                guard campusModel.loggedIn else {
                    store.clearLocalData()
                    examStore.clearLocalData()
                    return
                }
                await store.sync()
                await examStore.sync()
                store.loadFromLocal()
                examStore.loadFromLocal()
                computeCurrentWeek()
            }
            .alert("加载失败", isPresented: $showError) {
                Button("好") { store.clearError() }
            } message: {
                Text(store.lastError ?? "")
            }
            .alert("无法访问日历", isPresented: $showCalendarPermissionAlert) {
                Button("好") {}
            } message: {
                Text("请在系统设置中允许 Jinitaimei 写入日历。")
            }
            .onChange(of: store.lastError) { _, newValue in
                showError = (newValue != nil)
            }
            .onChange(of: store.schedules.count) { _, _ in
                clampSelectedWeek()
            }
            .onChange(of: store.selectedCalendarId) { _, _ in
                computeCurrentWeek()
            }
            .task {
                computeCurrentWeek()
                guard campusModel.loggedIn else {
                    store.clearLocalData()
                    return
                }
                await store.prepare()
                if examStore.exams.isEmpty {
                    await examStore.sync()
                }
                computeCurrentWeek()
            }
            .onChange(of: campusModel.loggedIn) { _, isLogged in
                computeCurrentWeek()
                if isLogged {
                    Task {
                        await store.prepare()
                        if examStore.exams.isEmpty {
                            await examStore.sync()
                        }
                        computeCurrentWeek()
                    }
                } else {
                    store.clearLocalData()
                    examStore.clearLocalData()
                    selectedWeek = 1
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无课表数据")
                .foregroundColor(.secondary)
            if campusModel.loggedIn {
                Button("立即同步") {
                    Task {
                await store.sync()
                store.loadFromLocal()
                computeCurrentWeek()
            }
        }
                .buttonStyle(.borderedProminent)
            } else {
                Text("请先在设置中登录校园账户")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listEmptyRowStyle(verticalPadding: 40)
    }

    private var weekRange: ClosedRange<Int> {
        store.selectedWeekRange
    }

    private var semesterName: String? {
        store.selectedCalendarName
    }

    /// 当前周按本机日期和缓存的学期开始日计算。
    ///
    /// 一系统返回的 `week` 只代表抓取当刻的当前周，不适合作为长期缓存；
    /// 学期边界缓存下来后，每次进入日程页都用系统日期即时换算，避免长期固定在旧周次。
    private func computeCurrentWeek() {
        guard let beginDate = semesterBeginDate() else { return }
        let secondsPerWeek: TimeInterval = 7 * 24 * 60 * 60
        let diff = Date().timeIntervalSince(beginDate)
        let week = diff >= 0 ? Int(diff / secondsPerWeek) + 1 : 1
        selectedWeek = max(weekRange.lowerBound, min(weekRange.upperBound, week))
    }

    private func semesterBeginDate() -> Date? {
        store.selectedTermBeginDate
    }

    private func weekStartDate(for week: Int) -> Date? {
        store.weekStartDate(for: week)
    }

    private var examsForSelectedWeek: [ExamScheduleItem] {
        guard let weekStart = weekStartDate(for: selectedWeek),
              let weekEnd = Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: weekStart) else {
            return []
        }
        return examStore.scheduledExams.filter { exam in
            guard let startDate = exam.startDate else { return false }
            return startDate >= weekStart && startDate < weekEnd
        }
    }

    private var currentTermScheduledExams: [ExamScheduleItem] {
        guard let calendarId = store.selectedCalendarId else {
            return examStore.scheduledExams
        }
        return examStore.scheduledExams.filter { $0.calendarId == calendarId }
    }

    private func clampSelectedWeek() {
        selectedWeek = max(weekRange.lowerBound, min(weekRange.upperBound, selectedWeek))
    }

    @MainActor
    private func requestCalendarAccess() async {
        showExportSheet = true
    }
}

private struct CourseExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let schedules: [CourseSchedule]
    let exams: [ExamScheduleItem]
    let semesterStart: Date

    @State private var selectedCalendar: EKCalendar?
    @State private var allKeys: [CourseExportKey] = []
    @State private var selectedKeys = Set<CourseExportKey>()
    @State private var includeExams = true
    @State private var showPermissionDeniedAlert = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var selectedAlarmMinutes = Set<Int>()
    @State private var writableCalendars: [EKCalendar] = []
    @State private var calendarAccessState: CalendarAccessState = .loading
    @State private var isExporting = false

    private let eventStore = EKEventStore()
    private let alarmOptions = [5, 10, 15, 30, 60]
    private let alarmDefaultsKey = "courseExportAlarmOffsetsMinutes"

    private var allSelected: Bool {
        !allKeys.isEmpty && selectedKeys.count == allKeys.count
    }

    private var canExport: Bool {
        !isExporting && !selectedKeys.isEmpty && selectedCalendar != nil && calendarAccessState.canWrite
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedKeys) {
                Section("课程") {
                    ForEach(allKeys) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(key.courseName)
                            Text(detailText(for: key))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(key)
                    }
                }

                if !exams.isEmpty {
                    Section {
                        Toggle("同时导出本学期考试", isOn: $includeExams)
                    } footer: {
                        Text("只会导出已有明确日期和起止时间的考试安排。")
                    }
                }

                Section {
                    Button {
                        selectedAlarmMinutes.removeAll()
                        saveAlarmSelection()
                    } label: {
                        HStack {
                            Text("无提醒")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedAlarmMinutes.isEmpty {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    ForEach(alarmOptions, id: \.self) { minutes in
                        Button {
                            toggleAlarm(minutes)
                        } label: {
                            HStack {
                                Text("课前 \(minutes) 分钟")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedAlarmMinutes.contains(minutes) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    Text("课前提醒")
                } footer: {
                    Text("会把所选提醒写入每一个导出的课程事件。")
                }

                Section {
                    calendarTargetContent
                } header: {
                    Text("目标日历")
                } footer: {
                    Text(calendarTargetFooter)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("导出到日历")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                allKeys = CourseCalendarExporter.calendarMap(for: schedules)
                    .keys
                    .sorted { lhs, rhs in
                        if lhs.courseName == rhs.courseName {
                            return lhs.id < rhs.id
                        }
                        return lhs.courseName < rhs.courseName
                    }
                selectedKeys = Set(allKeys)
                loadAlarmSelection()
            }
            .task {
                await prepareCalendarAccess()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(allSelected ? "取消全选" : "全选") {
                        selectedKeys = allSelected ? [] : Set(allKeys)
                    }
                    .disabled(allKeys.isEmpty || isExporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if selectedKeys.isEmpty {
                        Button("取消") {
                            dismiss()
                        }
                        .disabled(isExporting)
                    } else {
                        Button(isExporting ? "导出中" : "导出") {
                            guard let selectedCalendar else {
                                exportErrorMessage = "请选择一个可写入的日历。"
                                showExportError = true
                                return
                            }
                            export(to: selectedCalendar)
                        }
                        .disabled(!canExport)
                    }
                }
            }
            .alert("无法访问日历", isPresented: $showPermissionDeniedAlert) {
                Button("好") {}
            } message: {
                Text("请在系统设置中允许 Jinitaimei 写入日历。")
            }
            .alert("导出失败", isPresented: $showExportError) {
                Button("好") {}
            } message: {
                Text(exportErrorMessage)
            }
        }
    }

    @ViewBuilder
    private var calendarTargetContent: some View {
        switch calendarAccessState {
        case .loading:
            HStack {
                ProgressView()
                Text("正在读取日历权限")
                    .foregroundStyle(.secondary)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("无法访问日历")
                Text("请在系统设置中允许 Jinitaimei 访问日历。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重新检查权限") {
                    Task { await prepareCalendarAccess(force: true) }
                }
            }
        case .writeOnly:
            HStack {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedCalendar?.title ?? "系统默认日历")
                    Text("仅写入权限")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .full:
            if writableCalendars.isEmpty {
                Text("没有可写入的日历")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(writableCalendars, id: \.calendarIdentifier) { calendar in
                    Button {
                        selectedCalendar = calendar
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(cgColor: calendar.cgColor))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(calendar.title)
                                    .foregroundStyle(.primary)
                                Text(calendar.source.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedCalendar?.calendarIdentifier == calendar.calendarIdentifier {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
    }

    private var calendarTargetFooter: String {
        switch calendarAccessState {
        case .loading:
            return "正在准备目标日历。"
        case .denied:
            return "没有日历权限时无法导出课程。"
        case .writeOnly:
            return "当前只有写入权限，系统不允许列出所有日历；课程将写入默认日历。重复导出会更新 Jinitaimei 已导出的同一批课程，不会重复添加。"
        case .full:
            return "课程和考试会写入这里选中的日历。重复导出会更新 Jinitaimei 已导出的同一批课程，不会重复添加。"
        }
    }

    private func detailText(for key: CourseExportKey) -> String {
        let period = "\(key.startPeriod)-\(key.endPeriod)节"
        let weekday = "周\(weekdayText(key.dayOfWeek))"
        let location = key.location.isEmpty ? "地点未定" : key.location
        return "\(weekday) \(period) · \(location)"
    }

    private func weekdayText(_ day: Int) -> String {
        switch day {
        case 1: return "一"
        case 2: return "二"
        case 3: return "三"
        case 4: return "四"
        case 5: return "五"
        case 6: return "六"
        case 7: return "日"
        default: return "\(day)"
        }
    }

    @MainActor
    private func prepareCalendarAccess(force: Bool = false) async {
        if !force, calendarAccessState != .loading, selectedCalendar != nil {
            return
        }
        calendarAccessState = .loading

        let fullAccessGranted: Bool
        do {
            fullAccessGranted = try await eventStore.requestFullAccessToEvents()
        } catch {
            fullAccessGranted = false
        }

        if fullAccessGranted {
            writableCalendars = eventStore.calendars(for: .event)
                .filter(\.allowsContentModifications)
                .sorted { lhs, rhs in
                    if lhs.source.title == rhs.source.title {
                        return lhs.title < rhs.title
                    }
                    return lhs.source.title < rhs.source.title
                }
            if let defaultCalendar = eventStore.defaultCalendarForNewEvents,
               defaultCalendar.allowsContentModifications,
               writableCalendars.contains(where: { $0.calendarIdentifier == defaultCalendar.calendarIdentifier }) {
                selectedCalendar = defaultCalendar
            } else {
                selectedCalendar = writableCalendars.first
            }
            calendarAccessState = .full
            return
        }

        do {
            let writeOnlyGranted = try await eventStore.requestWriteOnlyAccessToEvents()
            if writeOnlyGranted, let defaultCalendar = eventStore.defaultCalendarForNewEvents {
                selectedCalendar = defaultCalendar
                writableCalendars = [defaultCalendar]
                calendarAccessState = .writeOnly
            } else {
                selectedCalendar = nil
                writableCalendars = []
                calendarAccessState = .denied
                showPermissionDeniedAlert = true
            }
        } catch {
            selectedCalendar = nil
            writableCalendars = []
            calendarAccessState = .denied
            showPermissionDeniedAlert = true
        }
    }

    private func export(to calendar: EKCalendar) {
        guard !isExporting else { return }
        isExporting = true
        do {
            try CourseCalendarExporter.export(
                schedules: schedules,
                selectedKeys: selectedKeys,
                semesterStart: semesterStart,
                to: calendar,
                eventStore: eventStore,
                alarmOffsetsMinutes: selectedAlarmMinutes
            )
            if includeExams && !exams.isEmpty {
                try ExamCalendarExporter.export(
                    exams: exams,
                    selectedExamIds: Set(exams.map(\.sourceId)),
                    to: calendar,
                    eventStore: eventStore,
                    alarmOffsetsMinutes: selectedAlarmMinutes
                )
            }
            dismiss()
        } catch {
            isExporting = false
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    private func loadAlarmSelection() {
        let stored = UserDefaults.standard.array(forKey: alarmDefaultsKey) as? [Int]
        selectedAlarmMinutes = Set(stored ?? [15, 30])
    }

    private func saveAlarmSelection() {
        UserDefaults.standard.set(selectedAlarmMinutes.sorted(), forKey: alarmDefaultsKey)
    }

    private func toggleAlarm(_ minutes: Int) {
        if selectedAlarmMinutes.contains(minutes) {
            selectedAlarmMinutes.remove(minutes)
        } else {
            selectedAlarmMinutes.insert(minutes)
        }
        saveAlarmSelection()
    }
}

private enum CalendarAccessState: Equatable {
    case loading
    case full
    case writeOnly
    case denied

    var canWrite: Bool {
        self == .full || self == .writeOnly
    }
}
