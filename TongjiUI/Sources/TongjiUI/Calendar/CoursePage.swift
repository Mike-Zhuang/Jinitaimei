import SwiftUI
import SwiftData
import TongjiKit

/// 日程 Tab 主页：按周展示同济课表。
///
/// 渲染思路参考 DanXi-swift `FudanUI/Pages/CoursePage.swift`：
/// - 顶部周次切换器（Picker / 滚动条）
/// - 主体周视图：7 列 × 14 节
public struct CoursePage: View {

    @Environment(\.modelContext) private var modelContext
    @StateObject private var store: CourseStore
    @State private var selectedWeek: Int = 1

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: CourseStore(modelContext: modelContext))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                weekPicker
                Divider()
                if store.schedules.isEmpty && !store.isLoading {
                    emptyState
                } else {
                    WeekGridView(courses: store.schedules(forWeek: selectedWeek))
                }
            }
            .navigationTitle("课表")
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
            .alert("加载失败", isPresented: .constant(store.lastError != nil)) {
                Button("好") { /* 由 store 内部消化 */ }
            } message: {
                Text(store.lastError ?? "")
            }
            .task {
                if store.schedules.isEmpty {
                    await store.sync()
                }
                computeCurrentWeek()
            }
        }
    }

    private var weekPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1...20, id: \.self) { week in
                    Button {
                        selectedWeek = week
                    } label: {
                        Text("第\(week)周")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedWeek == week
                                ? Color.accentColor.opacity(0.2)
                                : Color(.secondarySystemBackground)
                            )
                            .foregroundColor(selectedWeek == week ? .accentColor : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无课表数据")
                .foregroundColor(.secondary)
            Button("立即同步") {
                Task { await store.sync() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    /// 根据 Keychain 中缓存的 `beginDay` 估算当前周。
    private func computeCurrentWeek() {
        let credStore = CredentialStore.shared
        guard let beginDayMs = credStore.get(CredentialStore.Keys.tongjiCalendarBeginDayMs),
              let ms = Double(beginDayMs) else {
            return
        }
        let beginDate = Date(timeIntervalSince1970: ms / 1000.0)
        let secondsPerWeek: TimeInterval = 7 * 24 * 60 * 60
        let diff = Date().timeIntervalSince(beginDate)
        if diff > 0 {
            let week = Int(diff / secondsPerWeek) + 1
            selectedWeek = max(1, min(20, week))
        }
    }
}
