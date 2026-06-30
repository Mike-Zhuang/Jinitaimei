import SwiftData
import SwiftUI
import TongjiKit

public struct LaundryPage: View {
    @StateObject private var store: LaundryStore
    @State private var filter: LaundryMachineFilter = .all
    @State private var expandedRoomIds: Set<String> = []
    @AppStorage(LaundryPreferences.pinnedRoomIdKey) private var pinnedRoomId = ""

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: LaundryStore(modelContext: modelContext))
    }

    public var body: some View {
        List {
            summarySection
            filterSection
            roomSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("洗衣机")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.syncRooms(force: true)
            await syncPinnedRoomIfNeeded(force: true)
        }
        .task {
            if store.rooms.isEmpty {
                await store.syncRooms()
            }
            await syncPinnedRoomIfNeeded()
        }
        .alert("加载失败", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("好") { store.clearError() }
            Button("重试") {
                Task { await store.syncRooms(force: true) }
            }
            Button("清空会话并重试") {
                store.clearRemoteSession()
                Task { await store.syncRooms(force: true) }
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
                        Text("常用洗衣房")
                            .font(.headline)
                        Text(pinnedSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let pinnedRoom, store.loadingRoomIds.contains(pinnedRoom.id) {
                        ProgressView()
                    }
                }

                if let pinnedRoom {
                    LaundryPinnedRoomSummary(
                        room: pinnedRoom,
                        machines: store.machines(for: pinnedRoom),
                        error: store.error(for: pinnedRoom)
                    )

                    HStack {
                        Button("刷新此洗衣房") {
                            Task { await store.syncMachines(for: pinnedRoom, force: true) }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("取消置顶") {
                            pinnedRoomId = ""
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("在下面展开你常用的宿舍洗衣房，然后设为常用。以后首页和本页会优先同步它。")
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
                ForEach(LaundryMachineFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var roomSection: some View {
        if store.rooms.isEmpty && store.isLoadingRooms {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在同步洗衣房")
                        .foregroundStyle(.secondary)
                }
            }
        } else if store.rooms.isEmpty {
            Section {
                ContentUnavailableView(
                    "暂无洗衣机数据",
                    systemImage: "washer",
                    description: Text("洗衣机服务暂时没有返回附近洗衣房，可稍后重试。")
                )
                .listEmptyRowStyle()

                Button("重新同步") {
                    Task { await store.syncRooms(force: true) }
                }
            }
        } else {
            Section {
                ForEach(store.rooms) { room in
                    DisclosureGroup(isExpanded: expansionBinding(for: room)) {
                        LaundryRoomActionBar(
                            isPinned: isPinned(room),
                            isLoading: store.loadingRoomIds.contains(room.id),
                            onPin: { togglePinned(room) },
                            onRefresh: {
                                Task { await store.syncMachines(for: room, force: true) }
                            }
                        )
                        .padding(.top, 8)

                        if let error = store.error(for: room) {
                            LaundryRoomErrorView(message: error) {
                                Task { await store.syncMachines(for: room, force: true) }
                            }
                            .padding(.top, 8)
                        }

                        let machines = filteredMachines(for: room)
                        if store.loadingRoomIds.contains(room.id) && store.machines(for: room).isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在加载洗衣机")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        } else if machines.isEmpty {
                            Text(emptyMachineText(for: room))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(machines) { machine in
                                    LaundryMachineRow(machine: machine)
                                    if machine.id != machines.last?.id {
                                        Divider()
                                            .padding(.leading, 2)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    } label: {
                        LaundryRoomRow(
                            room: room,
                            machines: store.machines(for: room),
                            isLoading: store.loadingRoomIds.contains(room.id),
                            isPinned: isPinned(room)
                        )
                    }
                }
            } header: {
                Text("附近洗衣房")
            } footer: {
                Text("当前仅展示状态，不提交预约、支付、扫码或启动洗衣请求。")
            }
        }
    }

    private var pinnedRoom: LaundryRoom? {
        guard !pinnedRoomId.isEmpty else { return nil }
        return store.room(id: pinnedRoomId)
    }

    private var pinnedSubtitle: String {
        if let pinnedRoom {
            let machines = store.machines(for: pinnedRoom)
            if machines.isEmpty {
                return "\(pinnedRoom.displayName) · 尚未同步机器"
            }
            let summary = LaundryMachineSummary(machines: machines)
            return "\(pinnedRoom.displayName) · \(summary.idleCount)/\(summary.totalCount) 空闲"
        }
        if !store.rooms.isEmpty {
            return "已同步 \(store.rooms.count) 个洗衣房"
        }
        return "下拉刷新后同步洗衣房"
    }

    private func isPinned(_ room: LaundryRoom) -> Bool {
        pinnedRoomId == room.id
    }

    private func togglePinned(_ room: LaundryRoom) {
        if isPinned(room) {
            pinnedRoomId = ""
        } else {
            pinnedRoomId = room.id
            expandedRoomIds.insert(room.id)
            Task { await store.syncMachines(for: room, force: true) }
        }
    }

    private func syncPinnedRoomIfNeeded(force: Bool = false) async {
        guard !pinnedRoomId.isEmpty else { return }
        await store.syncPinnedRoom(id: pinnedRoomId, force: force)
    }

    private func expansionBinding(for room: LaundryRoom) -> Binding<Bool> {
        Binding {
            expandedRoomIds.contains(room.id)
        } set: { isExpanded in
            if isExpanded {
                expandedRoomIds.insert(room.id)
                Task {
                    await Task.yield()
                    await store.syncMachines(for: room)
                }
            } else {
                expandedRoomIds.remove(room.id)
            }
        }
    }

    private func filteredMachines(for room: LaundryRoom) -> [LaundryMachine] {
        store.machines(for: room).filter(filter.matches)
    }

    private func emptyMachineText(for room: LaundryRoom) -> String {
        if store.machines(for: room).isEmpty {
            return "暂无洗衣机数据"
        }
        return "当前筛选下暂无洗衣机"
    }
}

private enum LaundryMachineFilter: String, CaseIterable, Identifiable {
    case all
    case idle
    case running
    case offline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .idle: "空闲"
        case .running: "运行中"
        case .offline: "离线"
        }
    }

    func matches(_ machine: LaundryMachine) -> Bool {
        switch self {
        case .all:
            return true
        case .idle:
            return machine.status == .idle
        case .running:
            return machine.status == .running
        case .offline:
            return machine.status == .offline || machine.status == .unknown
        }
    }
}

private struct LaundryPinnedRoomSummary: View {
    let room: LaundryRoom
    let machines: [LaundryMachine]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(room.displayName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer()
                if !machines.isEmpty {
                    Text("\(summary.idleCount)/\(summary.totalCount) 空闲")
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
            } else if machines.isEmpty {
                Text("点“刷新此洗衣房”后只同步这个宿舍，不会扫描所有楼。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("运行中 \(summary.runningCount) · 离线 \(summary.offlineCount + summary.unknownCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: LaundryMachineSummary {
        LaundryMachineSummary(machines: machines)
    }
}

private struct LaundryRoomActionBar: View {
    let isPinned: Bool
    let isLoading: Bool
    let onPin: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            Button(isPinned ? "取消常用" : "设为常用", action: onPin)
                .buttonStyle(.bordered)
            Button("刷新此洗衣房", action: onRefresh)
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            Spacer()
        }
        .font(.caption)
    }
}

private struct LaundryRoomErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
            Button("重试此洗衣房", action: onRetry)
                .buttonStyle(.bordered)
                .font(.caption)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LaundryRoomRow: View {
    let room: LaundryRoom
    let machines: [LaundryMachine]
    let isLoading: Bool
    let isPinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text(room.displayName)
                        .font(.headline)
                        .lineLimit(2)
                    if isPinned {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                Spacer()
                trailingStatus
            }

            HStack(spacing: 8) {
                Text("洗衣机 \(room.washingMachineCount)")
                if room.dryerCount > 0 {
                    Text("烘干机 \(room.dryerCount)")
                }
                if let distance = room.distanceMessage?.nilIfEmpty {
                    Text(distance)
                }
                if machines.isEmpty {
                    Text("展开后同步")
                } else {
                    Text("运行中 \(summary.runningCount)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
        } else if !machines.isEmpty {
            Text("\(summary.idleCount)/\(summary.totalCount) 空闲")
                .font(.caption)
                .bold()
                .foregroundStyle(.green)
        }
    }

    private var summary: LaundryMachineSummary {
        LaundryMachineSummary(machines: machines)
    }
}

private struct LaundryMachineRow: View {
    let machine: LaundryMachine

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(machine.machineTypeName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(machine.status.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.12), in: Capsule())
                if machine.status == .running, let minutes = machine.remainingMinutes, minutes > 0 {
                    Text("约 \(minutes) 分钟")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 9)
    }

    private var subtitle: String {
        var parts = ["编号 \(machine.machineSn)"]
        if let description = machine.runningStatusDescription?.nilIfEmpty,
           description != machine.status.title {
            parts.append(description)
        }
        if machine.appointmentStatus == true {
            parts.append("可预约")
        }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch machine.status {
        case .idle:
            return .green
        case .running:
            return .blue
        case .offline:
            return .secondary
        case .unknown:
            return .orange
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
