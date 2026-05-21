import SwiftUI
import SwiftData
import TongjiKit

/// 日程 Tab 主页：按周展示同济课表。
///
/// 排版参考 DanXi-swift `FudanUI/Pages/CoursePage.swift`：
/// - 标题"日程"（inline）+ 右上角刷新按钮
/// - List 形态：第一个 Section 放周次 Stepper（第 N 周 - +）
/// - 第二个 Section 放周视图（节次时间侧栏 + 7 列日期 + 课程块）
public struct CoursePage: View {

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var store: CourseStore
    @State private var selectedWeek: Int = 1
    @State private var showError = false

    private let weekRange = 1...25

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
                            Text("第 \(selectedWeek) 周")
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
                    Button {
                        Task { await store.sync() }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isLoading)
                }
            }
            .refreshable {
                await store.sync()
            }
            .alert("加载失败", isPresented: $showError) {
                Button("好") { store.clearError() }
            } message: {
                Text(store.lastError ?? "")
            }
            .onChange(of: store.lastError) { _, newValue in
                showError = (newValue != nil)
            }
            .task {
                guard campusModel.loggedIn else { return }
                if store.schedules.isEmpty {
                    await store.sync()
                }
                computeCurrentWeek()
            }
            .onChange(of: campusModel.loggedIn) { _, isLogged in
                if isLogged && store.schedules.isEmpty {
                    Task { await store.sync() }
                    computeCurrentWeek()
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
            Button("立即同步") {
                Task { await store.sync() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    /// 根据 Keychain 中缓存的 `beginDay` 估算当前周。
    private func computeCurrentWeek() {
        guard let beginDate = semesterBeginDate() else { return }
        let secondsPerWeek: TimeInterval = 7 * 24 * 60 * 60
        let diff = Date().timeIntervalSince(beginDate)
        if diff > 0 {
            let week = Int(diff / secondsPerWeek) + 1
            selectedWeek = max(weekRange.lowerBound, min(weekRange.upperBound, week))
        }
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
}
