import SwiftUI
import SwiftData
import SafariServices
import TongjiKit

/// 卓越星活动列表页。
///
/// 形态参考 DanXi-swift `FudanUI/Pages/AnnouncementPage.swift` 的"可点开列表"：
/// 列表项 → Safari 详情。
public struct ActivityListPage: View {

    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var store: ActivityStore
    @State private var presentedURL: IdentifiedURL?
    @State private var showError = false
    @State private var showFilterSheet = false
    @State private var filterState = ActivityFilterState()

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: ActivityStore(modelContext: modelContext))
    }

    public var body: some View {
        List {
            if let summary = campusModel.starScoreSummary {
                Section {
                    StarScoreSummaryView(summary: summary)
                }
            }

            ForEach(filteredActivities, id: \.remoteId) { activity in
                Button {
                    if let link = activity.link, let url = URL(string: link) {
                        presentedURL = IdentifiedURL(url: url)
                    }
                } label: {
                    ActivityRow(activity: activity)
                }
                .buttonStyle(.plain)
            }
            if !store.isLoading {
                if store.activities.isEmpty {
                    ContentUnavailableView(
                        "暂无活动",
                        systemImage: "star.circle",
                        description: Text(campusModel.loggedIn ? "下拉或点击右上角刷新" : "公开活动可匿名浏览，登录后可同步个人星值")
                    )
                } else if filteredActivities.isEmpty {
                    ContentUnavailableView(
                        "没有匹配活动",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("请调整星星种类、星值或排序条件")
                    )
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("卓越星")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: filterState.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }

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
        .task {
            guard campusModel.loggedIn else { return }
            if store.activities.isEmpty {
                await store.sync()
            }
            await campusModel.refreshStarScoreSummary()
        }
        .onChange(of: campusModel.loggedIn) { _, newValue in
            if newValue && store.activities.isEmpty {
                Task { await store.sync() }
            }
            if newValue {
                Task { await campusModel.refreshStarScoreSummary() }
            }
        }
        .alert("加载失败", isPresented: $showError) {
            Button("好") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: store.lastError) { _, newValue in
            showError = (newValue != nil)
        }
        .sheet(item: $presentedURL) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showFilterSheet) {
            ActivityFilterSheet(filterState: $filterState)
        }
    }

    private var filteredActivities: [CampusActivity] {
        var result = store.activities
        if !filterState.selectedModuleCodes.isEmpty {
            result = result.filter { activity in
                guard let moduleCode = activity.moduleCode else { return false }
                return filterState.selectedModuleCodes.contains(moduleCode)
            }
        }
        if filterState.minimumPoints > 0 {
            result = result.filter { $0.starPoints >= filterState.minimumPoints }
        }
        switch filterState.sortOption {
        case .dateDescending:
            return result.sorted { $0.activityDate > $1.activityDate }
        case .pointsDescending:
            return result.sorted {
                if $0.starPoints == $1.starPoints {
                    return $0.activityDate > $1.activityDate
                }
                return $0.starPoints > $1.starPoints
            }
        case .pointsAscending:
            return result.sorted {
                if $0.starPoints == $1.starPoints {
                    return $0.activityDate > $1.activityDate
                }
                return $0.starPoints < $1.starPoints
            }
        }
    }
}

struct ActivityRow: View {
    let activity: CampusActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activity.title)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                if activity.activityDate > Date.distantPast {
                    Text(activity.activityDate.formatted(date: .abbreviated, time: .shortened))
                }
                if let loc = activity.location, !loc.isEmpty {
                    Text("·").foregroundColor(.secondary)
                    Text(loc)
                        .lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundColor(.secondary)

            HStack(spacing: 8) {
                if let moduleName = activity.moduleName {
                    Label(moduleName, systemImage: "star.fill")
                }
                if activity.starPoints > 0 {
                    Text("\(StarScoreSummary.formatScore(activity.starPoints)) 星")
                }
            }
            .font(.caption2)
            .foregroundColor(.orange)

            if let desc = activity.descriptionText, !desc.isEmpty {
                Text(desc)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private enum ActivitySortOption: String, CaseIterable, Identifiable {
    case dateDescending
    case pointsDescending
    case pointsAscending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateDescending: "活动时间最新优先"
        case .pointsDescending: "星值从高到低"
        case .pointsAscending: "星值从低到高"
        }
    }
}

private struct ActivityFilterState: Equatable {
    var selectedModuleCodes: Set<String> = []
    var minimumPoints: Double = 0
    var sortOption: ActivitySortOption = .dateDescending

    var isActive: Bool {
        !selectedModuleCodes.isEmpty || minimumPoints > 0 || sortOption != .dateDescending
    }

    mutating func reset() {
        selectedModuleCodes = []
        minimumPoints = 0
        sortOption = .dateDescending
    }
}

private struct ActivityFilterSheet: View {
    @Binding var filterState: ActivityFilterState
    @Environment(\.dismiss) private var dismiss

    private let modules = [
        ("hongwen", "弘文之星"),
        ("mingde", "明德之星"),
        ("shizhi", "矢志之星"),
        ("qiusuo", "求索之星"),
        ("lixing", "力行之星")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("星星种类") {
                    ForEach(modules, id: \.0) { code, name in
                        Button {
                            toggleModule(code)
                        } label: {
                            HStack {
                                Text(name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if filterState.selectedModuleCodes.contains(code) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Section("最低星值") {
                    Stepper(value: $filterState.minimumPoints, in: 0...20, step: 0.5) {
                        LabeledContent("星星数量 ≥") {
                            Text(filterState.minimumPoints == 0 ? "不限" : StarScoreSummary.formatScore(filterState.minimumPoints))
                        }
                    }
                }

                Section("排序") {
                    Picker("排序方式", selection: $filterState.sortOption) {
                        ForEach(ActivitySortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section {
                    Button("重置筛选") {
                        filterState.reset()
                    }
                    .disabled(!filterState.isActive)
                }
            }
            .navigationTitle("筛选与排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    dismiss()
                }
                .bold()
            }
        }
    }

    private func toggleModule(_ code: String) {
        if filterState.selectedModuleCodes.contains(code) {
            filterState.selectedModuleCodes.remove(code)
        } else {
            filterState.selectedModuleCodes.insert(code)
        }
    }
}

struct StarScoreSummaryView: View {
    let summary: StarScoreSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("个人星值", systemImage: "star.circle.fill")
                    .font(.callout)
                    .bold()
                    .foregroundColor(.orange)
                Spacer()
                Text(StarScoreSummary.formatScore(summary.totalScore))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], alignment: .leading, spacing: 8) {
                scoreItem("弘文", summary.hongwenScore)
                scoreItem("明德", summary.mingdeScore)
                scoreItem("矢志", summary.shizhiScore)
                scoreItem("求索", summary.qiusuoScore)
                scoreItem("力行", summary.lixingScore)
            }
        }
        .padding(.vertical, 4)
    }

    private func scoreItem(_ name: String, _ score: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(StarScoreSummary.formatScore(score))
                .font(.caption)
                .bold()
        }
    }
}

struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// SFSafariViewController 的 SwiftUI 包装，用于打开活动详情。
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
