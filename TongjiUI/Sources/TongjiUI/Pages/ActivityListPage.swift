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
            if !campusModel.loggedIn {
                ContentUnavailableView(
                    "请先登录校园账户",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("登录后可查看卓越星活动与个人星值")
                )
                .listEmptyRowStyle()
            } else if let summary = campusModel.starScoreSummary {
                Section {
                    StarScoreSummaryView(summary: summary)
                }
            }

            if campusModel.loggedIn {
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
                            description: Text("下拉或点击右上角刷新")
                        )
                        .listEmptyRowStyle()
                    } else if filteredActivities.isEmpty {
                        ContentUnavailableView(
                            "没有匹配活动",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("请调整星星种类、星值、活动状态或排序条件")
                        )
                        .listEmptyRowStyle()
                    }
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
                .disabled(!campusModel.loggedIn)

                Button {
                    Task { await store.sync() }
                } label: {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isLoading || !campusModel.loggedIn)
            }
        }
        .refreshable {
            guard campusModel.loggedIn else { return }
            await store.sync()
        }
        .task {
            guard campusModel.loggedIn else {
                store.clearLocalData()
                return
            }
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
            } else {
                store.clearLocalData()
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
            result = result.filter { Int($0.starPoints.rounded()) >= filterState.minimumPoints }
        }
        result = result.filter { filterState.selectedStatuses.contains(ActivityStatusFilter.status(for: $0)) }
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
                Text(ActivityStatusFilter.status(for: activity).title)
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

private enum ActivityStatusFilter: String, CaseIterable, Identifiable {
    case registrationOpen
    case activityOngoing
    case notStarted
    case signInOngoing
    case ended
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .registrationOpen: "报名进行中"
        case .activityOngoing: "活动进行中"
        case .notStarted: "活动未开始"
        case .signInOngoing: "签到中"
        case .ended: "活动已结束"
        case .unknown: "其他状态"
        }
    }

    static let defaultSelection: Set<ActivityStatusFilter> = [
        .registrationOpen,
        .activityOngoing,
        .notStarted,
        .signInOngoing,
        .unknown
    ]

    static func status(for activity: CampusActivity, now: Date = Date()) -> ActivityStatusFilter {
        if let progressName = activity.progressName {
            if progressName.contains("报名") && progressName.contains("进行") { return .registrationOpen }
            if progressName.contains("签到") && progressName.contains("进行") { return .signInOngoing }
            if progressName.contains("活动") && progressName.contains("进行") { return .activityOngoing }
            if progressName.contains("未开始") { return .notStarted }
            if progressName.contains("评价") || progressName.contains("结束") { return .ended }
        }
        if let endDate = activity.activityEndDate, endDate < now {
            return .ended
        }
        if activity.activityDate > now {
            return .notStarted
        }
        return .unknown
    }
}

private struct ActivityFilterState: Equatable {
    var selectedModuleCodes: Set<String> = []
    var selectedStatuses: Set<ActivityStatusFilter> = ActivityStatusFilter.defaultSelection
    var minimumPoints: Int = 0
    var sortOption: ActivitySortOption = .dateDescending

    var isActive: Bool {
        !selectedModuleCodes.isEmpty ||
        selectedStatuses != ActivityStatusFilter.defaultSelection ||
        minimumPoints > 0 ||
        sortOption != .dateDescending
    }

    mutating func reset() {
        selectedModuleCodes = []
        selectedStatuses = ActivityStatusFilter.defaultSelection
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
                    Stepper(value: $filterState.minimumPoints, in: 0...20, step: 1) {
                        LabeledContent("星星数量 ≥") {
                            Text(filterState.minimumPoints == 0 ? "不限" : "\(filterState.minimumPoints)")
                        }
                    }
                }

                Section {
                    ForEach(ActivityStatusFilter.allCases) { status in
                        Button {
                            toggleStatus(status)
                        } label: {
                            HStack {
                                Text(status.title)
                                    .foregroundColor(.primary)
                                Spacer()
                                if filterState.selectedStatuses.contains(status) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    Text("活动状态")
                } footer: {
                    Text("默认隐藏已结束活动；需要查看历史活动时可勾选“活动已结束”。")
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

    private func toggleStatus(_ status: ActivityStatusFilter) {
        if filterState.selectedStatuses.contains(status) {
            filterState.selectedStatuses.remove(status)
        } else {
            filterState.selectedStatuses.insert(status)
        }
    }
}

struct StarScoreSummaryView: View {
    let summary: StarScoreSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var scoreItems: [(name: String, score: Double)] {
        [
            ("弘文", summary.hongwenScore),
            ("明德", summary.mingdeScore),
            ("矢志", summary.shizhiScore),
            ("求索", summary.qiusuoScore),
            ("力行", summary.lixingScore)
        ]
    }

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

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { index in
                            scoreItem(scoreItems[index].name, scoreItems[index].score)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        ForEach(3..<5, id: \.self) { index in
                            scoreItem(scoreItems[index].name, scoreItems[index].score)
                                .frame(maxWidth: 92, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(scoreItems.indices, id: \.self) { index in
                        scoreItem(scoreItems[index].name, scoreItems[index].score)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
