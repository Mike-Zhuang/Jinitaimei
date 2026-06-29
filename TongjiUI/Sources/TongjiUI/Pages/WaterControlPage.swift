import SwiftData
import SwiftUI
import TongjiKit

public struct WaterControlPage: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var store: WaterControlStore
    @State private var filter: WaterDeviceFilter = .all
    @State private var expandedGroupIds: Set<String> = []
    @AppStorage(WaterControlPreferences.pinnedGroupIdKey) private var pinnedGroupId = ""

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: WaterControlStore(modelContext: modelContext))
    }

    public var body: some View {
        List {
            if !campusModel.loggedIn {
                ContentUnavailableView(
                    "请先登录校园账户",
                    systemImage: "drop.fill",
                    description: Text("登录后可查看智能控水器状态。")
                )
                .listEmptyRowStyle()
            } else {
                summarySection
                filterSection
                groupSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("智能控水")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            guard campusModel.loggedIn else { return }
            await store.syncGroups(force: true)
            await syncPinnedGroupIfNeeded(force: true)
        }
        .task {
            guard campusModel.loggedIn else { return }
            if store.groups.isEmpty {
                await store.syncGroups()
            }
            await syncPinnedGroupIfNeeded()
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            if !loggedIn {
                store.clearLocalData()
                expandedGroupIds.removeAll()
                pinnedGroupId = ""
            }
        }
        .alert("加载失败", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("好") { store.clearError() }
            if store.lastErrorCanRenewAuth {
                Button("重新获取登录态") {
                    Task {
                        _ = await WaterAuthCoordinator.shared.renewIfPossible(force: true)
                        await store.syncGroups(force: true)
                    }
                }
            } else {
                Button("重试") {
                    Task {
                        await store.syncGroups(force: true)
                    }
                }
            }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的宿舍")
                            .font(.headline)
                        Text(pinnedSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let pinnedGroup, store.loadingGroupIds.contains(pinnedGroup.id) {
                        ProgressView()
                    }
                }

                if let pinnedGroup {
                    WaterPinnedGroupSummary(
                        group: pinnedGroup,
                        devices: store.devices(for: pinnedGroup),
                        error: store.error(for: pinnedGroup)
                    )

                    HStack {
                        Button("刷新此宿舍") {
                            Task { await store.syncControllers(for: pinnedGroup, force: true) }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("取消置顶") {
                            pinnedGroupId = ""
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("在下面展开你的宿舍分组，然后设为我的宿舍。以后首页和本页只会优先同步这个宿舍。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let lastSync = store.lastSyncTime {
                    Text("同步于 \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            Picker("筛选", selection: $filter) {
                ForEach(WaterDeviceFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var groupSection: some View {
        if store.groups.isEmpty && store.isLoadingGroups {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在同步控水分组")
                        .foregroundStyle(.secondary)
                }
            }
        } else if store.groups.isEmpty {
            Section {
                ContentUnavailableView(
                    "暂无控水数据",
                    systemImage: "drop.triangle",
                    description: Text("如果你刚完成登录，可以尝试重新获取水控登录态。")
                )
                .listEmptyRowStyle()

                Button("重新获取水控登录态") {
                    Task {
                        _ = await WaterAuthCoordinator.shared.renewIfPossible(force: true)
                        await store.syncGroups(force: true)
                    }
                }
            }
        } else {
            Section {
                ForEach(store.groups) { group in
                    DisclosureGroup(isExpanded: expansionBinding(for: group)) {
                        WaterGroupActionBar(
                            isPinned: isPinned(group),
                            isLoading: store.loadingGroupIds.contains(group.id),
                            onPin: { togglePinned(group) },
                            onRefresh: {
                                Task { await store.syncControllers(for: group, force: true) }
                            }
                        )
                        .padding(.top, 8)

                        if let error = store.error(for: group) {
                            WaterGroupErrorView(
                                message: error,
                                canRenewAuth: store.errorCanRenewAuth(for: group),
                                onRetry: {
                                    Task { await store.syncControllers(for: group, force: true) }
                                },
                                onRenew: {
                                    Task {
                                        _ = await WaterAuthCoordinator.shared.renewIfPossible(force: true)
                                        await store.syncControllers(for: group, force: true)
                                    }
                                }
                            )
                            .padding(.top, 8)
                        }

                        let devices = filteredDevices(for: group)
                        if store.loadingGroupIds.contains(group.id) && store.devices(for: group).isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在加载控水器")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        } else if devices.isEmpty {
                            Text(emptyDeviceText(for: group))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(devices) { device in
                                    WaterDeviceRow(device: device)
                                    if device.id != devices.last?.id {
                                        Divider()
                                            .padding(.leading, 2)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    } label: {
                        WaterGroupRow(
                            group: group,
                            devices: store.devices(for: group),
                            isLoading: store.loadingGroupIds.contains(group.id),
                            isPinned: isPinned(group)
                        )
                    }
                }
            } header: {
                Text("全部分组")
            } footer: {
                Text("当前仅展示状态，不提交预约、开关水或控制请求。")
            }
        }
    }

    private var pinnedGroup: WaterControlGroup? {
        guard !pinnedGroupId.isEmpty else { return nil }
        return store.group(id: pinnedGroupId)
    }

    private var pinnedSubtitle: String {
        if let pinnedGroup {
            let devices = store.devices(for: pinnedGroup)
            if devices.isEmpty {
                return "\(pinnedGroup.name) · 尚未同步控水器"
            }
            let available = devices.filter { $0.status == .available }.count
            return "\(pinnedGroup.name) · \(available)/\(devices.count) 空闲"
        }
        if !store.groups.isEmpty {
            return "已同步 \(store.groups.count) 个分组"
        }
        return "下拉刷新后同步分组"
    }

    private func isPinned(_ group: WaterControlGroup) -> Bool {
        pinnedGroupId == group.id
    }

    private func togglePinned(_ group: WaterControlGroup) {
        if isPinned(group) {
            pinnedGroupId = ""
        } else {
            pinnedGroupId = group.id
            expandedGroupIds.insert(group.id)
            Task { await store.syncControllers(for: group, force: true) }
        }
    }

    private func syncPinnedGroupIfNeeded(force: Bool = false) async {
        guard !pinnedGroupId.isEmpty else { return }
        await store.syncPinnedGroup(id: pinnedGroupId, force: force)
    }

    private func expansionBinding(for group: WaterControlGroup) -> Binding<Bool> {
        Binding {
            expandedGroupIds.contains(group.id)
        } set: { isExpanded in
            if isExpanded {
                expandedGroupIds.insert(group.id)
                Task {
                    await Task.yield()
                    await store.syncControllers(for: group)
                }
            } else {
                expandedGroupIds.remove(group.id)
            }
        }
    }

    private func filteredDevices(for group: WaterControlGroup) -> [WaterControlDevice] {
        store.devices(for: group).filter(filter.matches)
    }

    private func emptyDeviceText(for group: WaterControlGroup) -> String {
        if store.devices(for: group).isEmpty {
            return "暂无控水器数据"
        }
        return "当前筛选下暂无控水器"
    }
}

private enum WaterDeviceFilter: String, CaseIterable, Identifiable {
    case all
    case available
    case inUse
    case problem

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .available: "空闲"
        case .inUse: "使用中"
        case .problem: "异常"
        }
    }

    func matches(_ device: WaterControlDevice) -> Bool {
        switch self {
        case .all:
            return true
        case .available:
            return device.status == .available
        case .inUse:
            return device.status == .inUse
        case .problem:
            return device.status.isProblematic
        }
    }
}

private struct WaterSummaryPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WaterPinnedGroupSummary: View {
    let group: WaterControlGroup
    let devices: [WaterControlDevice]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer()
                if !devices.isEmpty {
                    Text("\(availableCount)/\(devices.count) 空闲")
                        .font(.callout)
                        .bold()
                        .foregroundStyle(.green)
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if devices.isEmpty {
                Text("点“刷新此宿舍”后只同步这个分组，不会全量扫描所有楼。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("使用中 \(inUseCount) · 异常 \(problemCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var availableCount: Int {
        devices.filter { $0.status == .available }.count
    }

    private var inUseCount: Int {
        devices.filter { $0.status == .inUse }.count
    }

    private var problemCount: Int {
        devices.filter { $0.status.isProblematic }.count
    }
}

private struct WaterGroupActionBar: View {
    let isPinned: Bool
    let isLoading: Bool
    let onPin: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            Button(isPinned ? "取消置顶" : "设为我的宿舍", action: onPin)
                .buttonStyle(.bordered)
            Button("刷新此宿舍", action: onRefresh)
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            Spacer()
        }
        .font(.caption)
    }
}

private struct WaterGroupErrorView: View {
    let message: String
    let canRenewAuth: Bool
    let onRetry: () -> Void
    let onRenew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
            HStack {
                Button("重试此宿舍", action: onRetry)
                    .buttonStyle(.bordered)
                if canRenewAuth {
                    Button("重新获取登录态", action: onRenew)
                        .buttonStyle(.bordered)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WaterGroupRow: View {
    let group: WaterControlGroup
    let devices: [WaterControlDevice]
    let isLoading: Bool
    let isPinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(2)
                    if isPinned {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if !devices.isEmpty {
                    Text("\(availableCount)/\(devices.count) 空闲")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                Text("编号 \(group.id)")
                if devices.isEmpty {
                    Text("展开后同步")
                } else {
                    Text("使用中 \(inUseCount)")
                    Text("异常 \(problemCount)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var availableCount: Int {
        devices.filter { $0.status == .available }.count
    }

    private var inUseCount: Int {
        devices.filter { $0.status == .inUse }.count
    }

    private var problemCount: Int {
        devices.filter { $0.status.isProblematic }.count
    }
}

private struct WaterDeviceRow: View {
    let device: WaterControlDevice

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text("编号 \(device.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(device.status.title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 9)
    }

    private var statusColor: Color {
        switch device.status {
        case .available:
            return .green
        case .inUse:
            return .blue
        case .locked, .alarm:
            return .orange
        case .offline, .unknown:
            return .secondary
        }
    }
}
