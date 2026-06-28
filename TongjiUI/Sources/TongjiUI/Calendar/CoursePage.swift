import SwiftUI
import SwiftData
import TongjiKit
import EventKit
import EventKitUI

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
                    if !store.terms.isEmpty {
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
                                ForEach(store.terms) { term in
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
        let eventStore = EKEventStore()
        do {
            let granted = try await eventStore.requestWriteOnlyAccessToEvents()
            if granted {
                showExportSheet = true
            } else {
                showCalendarPermissionAlert = true
            }
        } catch {
            showCalendarPermissionAlert = true
        }
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
    @State private var showCalendarChooser = false
    @State private var showPermissionDeniedAlert = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var selectedAlarmMinutes = Set<Int>()

    private let eventStore = EKEventStore()
    private let alarmOptions = [5, 10, 15, 30, 60]
    private let alarmDefaultsKey = "courseExportAlarmOffsetsMinutes"

    private var allSelected: Bool {
        !allKeys.isEmpty && selectedKeys.count == allKeys.count
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(allSelected ? "取消全选" : "全选") {
                        selectedKeys = allSelected ? [] : Set(allKeys)
                    }
                    .disabled(allKeys.isEmpty)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if selectedKeys.isEmpty {
                        Button("取消") {
                            dismiss()
                        }
                    } else {
                        Button("导出") {
                            Task { await presentCalendarChooser() }
                        }
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
            .sheet(isPresented: $showCalendarChooser) {
                CalendarChooserSheet(selectedCalendar: $selectedCalendar, eventStore: eventStore)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let selectedCalendar {
                            export(to: selectedCalendar)
                        }
                    }
            }
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
    private func presentCalendarChooser() async {
        do {
            let granted = try await eventStore.requestWriteOnlyAccessToEvents()
            showCalendarChooser = granted
            showPermissionDeniedAlert = !granted
        } catch {
            showPermissionDeniedAlert = true
        }
    }

    private func export(to calendar: EKCalendar) {
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

private struct CalendarChooserSheet: UIViewControllerRepresentable {
    @Binding var selectedCalendar: EKCalendar?
    @Environment(\.dismiss) private var dismiss
    let eventStore: EKEventStore

    func makeUIViewController(context: Context) -> UINavigationController {
        let chooser = EKCalendarChooser(
            selectionStyle: .single,
            displayStyle: .allCalendars,
            entityType: .event,
            eventStore: eventStore
        )
        chooser.selectedCalendars = []
        chooser.delegate = context.coordinator
        chooser.showsDoneButton = true
        return UINavigationController(rootViewController: chooser)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, EKCalendarChooserDelegate {
        let parent: CalendarChooserSheet

        init(_ parent: CalendarChooserSheet) {
            self.parent = parent
        }

        func calendarChooserDidFinish(_ calendarChooser: EKCalendarChooser) {
            if let calendar = calendarChooser.selectedCalendars.first {
                parent.selectedCalendar = calendar
            }
            parent.dismiss()
        }

        func calendarChooserDidCancel(_ calendarChooser: EKCalendarChooser) {
            parent.dismiss()
        }
    }
}
