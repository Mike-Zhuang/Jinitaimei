import EventKit
import EventKitUI
import SwiftData
import SwiftUI
import TongjiKit

public struct ExamSchedulePage: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var store: ExamScheduleStore
    @State private var selectedExam: ExamScheduleItem?
    @State private var showExportSheet = false

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: ExamScheduleStore(modelContext: modelContext))
    }

    public var body: some View {
        List {
            if !campusModel.loggedIn {
                ContentUnavailableView(
                    "请先登录校园账户",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("登录后可查看考试安排。")
                )
                .listEmptyRowStyle()
            } else {
                headerSection

                if let remark = store.switchRemark, !remark.isEmpty {
                    Section {
                        Label(remark, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if store.scheduledExams.isEmpty, store.unscheduledExams.isEmpty, !store.isLoading {
                    ContentUnavailableView("暂无考试安排", systemImage: "book.closed")
                        .listEmptyRowStyle()
                }

                if !store.scheduledExams.isEmpty {
                    Section("已排定时间") {
                        ForEach(store.scheduledExams) { exam in
                            Button {
                                selectedExam = exam
                            } label: {
                                ExamRow(exam: exam, scheduled: true)
                            }
                            .tint(.primary)
                        }
                    }
                }

                if !store.unscheduledExams.isEmpty {
                    Section("考察 / 未排定") {
                        ForEach(store.unscheduledExams) { exam in
                            Button {
                                selectedExam = exam
                            } label: {
                                ExamRow(exam: exam, scheduled: false)
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("考试安排")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            guard campusModel.loggedIn else { return }
            await store.sync()
        }
        .task {
            guard campusModel.loggedIn, store.exams.isEmpty else { return }
            await store.sync()
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            if !loggedIn {
                store.clearLocalData()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExportSheet = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .disabled(store.scheduledExams.isEmpty)
            }
        }
        .sheet(item: $selectedExam) { exam in
            ExamDetailSheet(exam: exam)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showExportSheet) {
            ExamExportSheet(exams: store.scheduledExams)
        }
        .alert("加载失败", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("好") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.calendarName ?? "当前学期")
                        .font(.headline)
                    if let lastSync = store.lastSyncTime {
                        Text("同步于 \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(store.isLoading ? "正在同步考试安排" : "下拉刷新同步考试安排")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isLoading {
                    ProgressView()
                }
            }
        }
    }
}

private struct ExamRow: View {
    let exam: ExamScheduleItem
    let scheduled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(exam.courseName)
                    .font(.headline)
                if scheduled {
                    Text("\(exam.displayDate)  \(exam.displayTime)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(exam.displayRemark)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                if scheduled {
                    Text(exam.displayLocation)
                        .font(.footnote)
                        .fontWeight(.semibold)
                    if !exam.newCourseCode.isEmpty {
                        Text(exam.newCourseCode)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("考察")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ExamDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exam: ExamScheduleItem

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(exam.courseName)
                            .font(.title3)
                            .bold()
                        if !exam.newCourseCode.isEmpty {
                            Text(exam.newCourseCode)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("考试信息") {
                    LabeledContent("类型", value: exam.hasScheduledTime ? "考试" : "考察")
                    LabeledContent("日期", value: exam.hasScheduledTime ? exam.displayDate : "未排定")
                    LabeledContent("时间", value: exam.hasScheduledTime ? exam.displayTime : "未排定")
                    LabeledContent("地点", value: exam.hasScheduledTime ? exam.displayLocation : "未排定")
                    if !exam.newTeachingClassCode.isEmpty {
                        LabeledContent("教学班", value: exam.newTeachingClassCode)
                    }
                }

                if !exam.displayRemark.isEmpty {
                    Section("备注") {
                        Text(exam.displayRemark)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("考试详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }
}

private struct ExamExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exams: [ExamScheduleItem]

    @State private var selectedExamIds: Set<Int> = []
    @State private var selectedAlarmMinutes: Set<Int> = []
    @State private var selectedCalendar: EKCalendar?
    @State private var showCalendarChooser = false
    @State private var showPermissionDeniedAlert = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var isExporting = false

    private let eventStore = EKEventStore()
    private let alarmOptions = [5, 10, 15, 30, 60]
    private let alarmDefaultsKey = "exam-export-alarm-minutes"

    private var allSelected: Bool {
        selectedExamIds.count == exams.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section("考试") {
                    ForEach(exams) { exam in
                        Button {
                            toggleExam(exam)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(exam.courseName)
                                        .foregroundStyle(.primary)
                                    Text("\(exam.displayDate) \(exam.displayTime)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedExamIds.contains(exam.sourceId) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
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
                                Text("考前 \(minutes) 分钟")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedAlarmMinutes.contains(minutes) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    Text("考前提醒")
                } footer: {
                    Text("只会导出有明确日期和起止时间的考试。")
                }
            }
            .navigationTitle("添加到日历")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                selectedExamIds = Set(exams.map(\.sourceId))
                loadAlarmSelection()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(allSelected ? "取消全选" : "全选") {
                        selectedExamIds = allSelected ? [] : Set(exams.map(\.sourceId))
                    }
                    .disabled(isExporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if selectedExamIds.isEmpty {
                        Button("取消") { dismiss() }
                            .disabled(isExporting)
                    } else {
                        Button(isExporting ? "导出中" : "导出") {
                            Task { await presentCalendarChooser() }
                        }
                        .disabled(isExporting)
                    }
                }
            }
            .alert("无法访问日历", isPresented: $showPermissionDeniedAlert) {
                Button("好") {}
            } message: {
                Text("请在系统设置中允许济你太美写入日历。")
            }
            .alert("导出失败", isPresented: $showExportError) {
                Button("好") {}
            } message: {
                Text(exportErrorMessage)
            }
            .sheet(isPresented: $showCalendarChooser) {
                ExamCalendarChooserSheet(selectedCalendar: $selectedCalendar, eventStore: eventStore)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let selectedCalendar {
                            export(to: selectedCalendar)
                        }
                    }
            }
        }
    }

    @MainActor
    private func presentCalendarChooser() async {
        selectedCalendar = nil
        do {
            let granted = try await eventStore.requestWriteOnlyAccessToEvents()
            showCalendarChooser = granted
            showPermissionDeniedAlert = !granted
        } catch {
            showPermissionDeniedAlert = true
        }
    }

    private func export(to calendar: EKCalendar) {
        guard !isExporting else { return }
        isExporting = true
        do {
            try ExamCalendarExporter.export(
                exams: exams,
                selectedExamIds: selectedExamIds,
                to: calendar,
                eventStore: eventStore,
                alarmOffsetsMinutes: selectedAlarmMinutes
            )
            dismiss()
        } catch {
            isExporting = false
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    private func toggleExam(_ exam: ExamScheduleItem) {
        if selectedExamIds.contains(exam.sourceId) {
            selectedExamIds.remove(exam.sourceId)
        } else {
            selectedExamIds.insert(exam.sourceId)
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

private struct ExamCalendarChooserSheet: UIViewControllerRepresentable {
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
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, EKCalendarChooserDelegate {
        let parent: ExamCalendarChooserSheet

        init(parent: ExamCalendarChooserSheet) {
            self.parent = parent
        }

        func calendarChooserDidFinish(_ calendarChooser: EKCalendarChooser) {
            parent.selectedCalendar = calendarChooser.selectedCalendars.first
            parent.dismiss()
        }

        func calendarChooserDidCancel(_ calendarChooser: EKCalendarChooser) {
            parent.selectedCalendar = nil
            parent.dismiss()
        }
    }
}
