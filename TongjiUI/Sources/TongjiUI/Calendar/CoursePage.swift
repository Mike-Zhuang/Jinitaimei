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
    @State private var selectedWeek: Int = 1
    @State private var showError = false
    @State private var showExportSheet = false
    @State private var showCalendarPermissionAlert = false

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: CourseStore(modelContext: modelContext))
    }

    public var body: some View {
        NavigationStack {
            List {
                if store.schedules.isEmpty && !store.isLoading {
                    emptyState
                } else {
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
                            weekStartDate: weekStartDate(for: selectedWeek)
                        )
                        .listRowInsets(EdgeInsets())
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
                                computeCurrentWeek()
                            }
                        } label: {
                            Label("刷新课表", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isLoading)

                        Button {
                            Task { await requestCalendarAccess() }
                        } label: {
                            Label("导出到日历", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.schedules.isEmpty || semesterBeginDate() == nil)
                    } label: {
                        if store.isLoading {
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
                        semesterStart: beginDate
                    )
                }
            }
            .refreshable {
                await store.sync()
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
            .task {
                computeCurrentWeek()
                guard campusModel.loggedIn else { return }
                await refreshCalendarMetadataIfNeeded()
                if store.schedules.isEmpty {
                    await store.sync()
                }
                computeCurrentWeek()
            }
            .onChange(of: campusModel.loggedIn) { _, isLogged in
                computeCurrentWeek()
                if isLogged {
                    Task {
                        await refreshCalendarMetadataIfNeeded()
                        if store.schedules.isEmpty {
                            await store.sync()
                        }
                        computeCurrentWeek()
                    }
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private var weekRange: ClosedRange<Int> {
        let credStore = CredentialStore.shared
        if let weekNumText = credStore.get(CredentialStore.Keys.tongjiCalendarWeekNum),
           let weekNum = Int(weekNumText), weekNum > 0 {
            return 1...weekNum
        }
        if let maxWeek = store.schedules.map(\.weekNumber).max(), maxWeek > 0 {
            return 1...maxWeek
        }
        return 1...1
    }

    private var semesterName: String? {
        CredentialStore.shared.get(CredentialStore.Keys.tongjiCalendarSimpleName)
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

    @MainActor
    private func refreshCalendarMetadataIfNeeded() async {
        guard needsCalendarMetadataRefresh() else {
            return
        }
        do {
            try await CourseAPI().refreshCalendarMetadata()
        } catch {
            print("[Course] 校历元数据刷新失败: \(error)")
        }
    }

    private func needsCalendarMetadataRefresh() -> Bool {
        let credStore = CredentialStore.shared
        guard semesterBeginDate() != nil,
              credStore.get(CredentialStore.Keys.tongjiCalendarId)?.isEmpty == false,
              let weekNumText = credStore.get(CredentialStore.Keys.tongjiCalendarWeekNum),
              Int(weekNumText) != nil else {
            return true
        }
        guard let endDayMs = credStore.get(CredentialStore.Keys.tongjiCalendarEndDayMs),
              let ms = Double(endDayMs) else {
            return false
        }
        return Date().timeIntervalSince1970 * 1000 > ms
    }

    private func semesterBeginDate() -> Date? {
        let credStore = CredentialStore.shared
        guard let beginDayMs = credStore.get(CredentialStore.Keys.tongjiCalendarBeginDayMs),
              let ms = Double(beginDayMs) else {
            return nil
        }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }

    private func weekStartDate(for week: Int) -> Date? {
        guard let beginDate = semesterBeginDate() else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(byAdding: .day, value: (week - 1) * 7, to: beginDate)
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
    let semesterStart: Date

    @State private var selectedCalendar: EKCalendar?
    @State private var allKeys: [CourseExportKey] = []
    @State private var selectedKeys = Set<CourseExportKey>()
    @State private var showCalendarChooser = false
    @State private var showPermissionDeniedAlert = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""

    private let eventStore = EKEventStore()

    private var allSelected: Bool {
        !allKeys.isEmpty && selectedKeys.count == allKeys.count
    }

    var body: some View {
        NavigationStack {
            List(allKeys, selection: $selectedKeys) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.courseName)
                    Text(detailText(for: key))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(key)
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
                eventStore: eventStore
            )
            dismiss()
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
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
