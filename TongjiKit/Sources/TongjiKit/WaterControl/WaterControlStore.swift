import Foundation
import SwiftData

@MainActor
public final class WaterControlStore: ObservableObject, CampusLocalStore {
    @Published public private(set) var groups: [WaterControlGroup] = []
    @Published public private(set) var devicesByGroup: [String: [WaterControlDevice]] = [:]
    @Published public private(set) var isLoadingGroups = false
    @Published public private(set) var loadingGroupIds: Set<String> = []
    @Published public private(set) var groupErrors: [String: String] = [:]
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastErrorCanRenewAuth = false
    @Published public private(set) var lastSyncTime: Date?

    private let context: ModelContext
    private let api: WaterControlAPI
    private var groupErrorCanRenewAuth: [String: Bool] = [:]
    private static var groupsTask: Task<[WaterControlGroup], Error>?

    public init(modelContext: ModelContext, api: WaterControlAPI = WaterControlAPI()) {
        self.context = modelContext
        self.api = api
        loadFromLocal()
    }

    public var allDevices: [WaterControlDevice] {
        devicesByGroup.values.flatMap { $0 }
    }

    public var summary: WaterControlSummary {
        WaterControlSummary(devices: allDevices)
    }

    public func devices(for group: WaterControlGroup) -> [WaterControlDevice] {
        devicesByGroup[group.id] ?? []
    }

    public func error(for group: WaterControlGroup) -> String? {
        groupErrors[group.id]
    }

    public func errorCanRenewAuth(for group: WaterControlGroup) -> Bool {
        groupErrorCanRenewAuth[group.id] ?? false
    }

    public func group(id: String) -> WaterControlGroup? {
        groups.first { $0.id == id }
    }

    public func syncGroups(force: Bool = false) async {
        if isLoadingGroups { return }
        isLoadingGroups = true
        defer { isLoadingGroups = false }
        clearError()

        do {
            let remoteGroups = try await sharedGroups(force: force)
            let syncTime = Date()
            try clearGroupSnapshots()
            for group in remoteGroups {
                context.insert(WaterControlGroupSnapshot(
                    groupId: group.id,
                    name: group.name,
                    posNum: group.posNum,
                    warnPosNum: group.warnPosNum,
                    useFreeRate: group.useFreeRate,
                    bookRate: group.bookRate,
                    actkind: group.actkind,
                    bookCode: group.bookCode,
                    syncTime: syncTime
                ))
            }
            try context.save()
            loadFromLocal()
            notifyDataDidChange()
        } catch let error as AuthError {
            record(error: error)
        } catch {
            record(message: error.localizedDescription, canRenewAuth: false)
        }
    }

    public func syncControllers(for group: WaterControlGroup, force: Bool = false) async {
        if loadingGroupIds.contains(group.id) { return }
        if !force, devicesByGroup[group.id]?.isEmpty == false { return }
        loadingGroupIds.insert(group.id)
        defer { loadingGroupIds.remove(group.id) }
        setGroupError(nil, groupId: group.id, canRenewAuth: false)

        do {
            let devices = try await withWaterControlAuthRetry {
                try await api.fetchControllers(for: group)
            }
            let syncTime = Date()
            try clearDeviceSnapshots(groupId: group.id)
            for device in devices {
                context.insert(WaterControlDeviceSnapshot(
                    deviceId: device.id,
                    groupId: device.groupId,
                    groupName: device.groupName,
                    name: device.name,
                    posNum: device.posNum,
                    warnPosNum: device.warnPosNum,
                    useFreeRate: device.useFreeRate,
                    bookRate: device.bookRate,
                    actkind: device.actkind,
                    bookCode: device.bookCode,
                    syncTime: syncTime
                ))
            }
            try context.save()
            loadFromLocal()
            notifyDataDidChange()
        } catch let error as AuthError {
            recordGroupError(error: error, groupId: group.id)
        } catch {
            recordGroupError(message: error.localizedDescription, groupId: group.id)
        }
    }

    public func syncSummary(force: Bool = false, groupLimit: Int = 2) async {
        await syncGroups(force: force)
        guard lastError == nil else { return }
        for group in groups.prefix(groupLimit) {
            await syncControllers(for: group, force: force)
        }
    }

    public func syncPinnedGroup(id: String, force: Bool = false) async {
        if groups.isEmpty {
            await syncGroups(force: force)
        }
        guard let group = group(id: id) else { return }
        await syncControllers(for: group, force: force)
    }

    public func loadFromLocal() {
        do {
            let groupSnapshots = try context.fetch(
                FetchDescriptor<WaterControlGroupSnapshot>(
                    sortBy: [SortDescriptor(\.name)]
                )
            )
            groups = groupSnapshots
                .map { $0.asGroup() }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let deviceSnapshots = try context.fetch(
                FetchDescriptor<WaterControlDeviceSnapshot>(
                    sortBy: [SortDescriptor(\.groupName), SortDescriptor(\.name)]
                )
            )
            let devices = deviceSnapshots.map { $0.asDevice() }
            devicesByGroup = Dictionary(grouping: devices, by: \.groupId)
            lastSyncTime = (groupSnapshots.map { $0.syncTime } + deviceSnapshots.map { $0.syncTime }).max()
        } catch {
            groups = []
            devicesByGroup = [:]
            groupErrors = [:]
            groupErrorCanRenewAuth = [:]
            lastSyncTime = nil
            lastError = error.localizedDescription
        }
    }

    public func clearError() {
        lastError = nil
        lastErrorCanRenewAuth = false
        groupErrors = [:]
        groupErrorCanRenewAuth = [:]
    }

    public func clearLocalData() {
        do {
            try clearGroupSnapshots()
            for item in try context.fetch(FetchDescriptor<WaterControlDeviceSnapshot>()) {
                context.delete(item)
            }
            try context.save()
        } catch {
            record(message: error.localizedDescription, canRenewAuth: false)
        }
        WaterAuthCoordinator.shared.clearCredentials()
        api.clearCachedToken()
        groups = []
        devicesByGroup = [:]
        groupErrors = [:]
        groupErrorCanRenewAuth = [:]
        lastSyncTime = nil
        UserDefaults.standard.removeObject(forKey: WaterControlPreferences.pinnedGroupIdKey)
        notifyDataDidChange()
    }

    private func record(error: AuthError) {
        switch error {
        case .notLoggedIn, .expired:
            record(message: error.errorDescription ?? "水控登录态已失效", canRenewAuth: true)
        case .loginFlowFailed, .mfaRequired:
            record(message: error.errorDescription ?? "水控加载失败", canRenewAuth: false)
        }
    }

    private func record(message: String, canRenewAuth: Bool) {
        lastError = message
        lastErrorCanRenewAuth = canRenewAuth
    }

    private func recordGroupError(error: AuthError, groupId: String) {
        let message = error.errorDescription ?? "控水器同步失败"
        switch error {
        case .notLoggedIn, .expired:
            setGroupError(message, groupId: groupId, canRenewAuth: true)
            if groups.isEmpty {
                record(message: message, canRenewAuth: true)
            }
        case .loginFlowFailed, .mfaRequired:
            setGroupError(message, groupId: groupId, canRenewAuth: false)
            break
        }
    }

    private func recordGroupError(message: String, groupId: String) {
        setGroupError(message, groupId: groupId, canRenewAuth: false)
    }

    private func setGroupError(_ message: String?, groupId: String, canRenewAuth: Bool) {
        var next = groupErrors
        var nextCanRenew = groupErrorCanRenewAuth
        next[groupId] = message
        nextCanRenew[groupId] = message == nil ? nil : canRenewAuth
        groupErrors = next
        groupErrorCanRenewAuth = nextCanRenew
    }

    private func sharedGroups(force: Bool) async throws -> [WaterControlGroup] {
        if let task = Self.groupsTask {
            return try await task.value
        }
        let task = Task { [api] in
            try await withWaterControlAuthRetry {
                return try await api.fetchGroups()
            }
        }
        Self.groupsTask = task
        defer { Self.groupsTask = nil }
        return try await task.value
    }

    private func clearGroupSnapshots() throws {
        for item in try context.fetch(FetchDescriptor<WaterControlGroupSnapshot>()) {
            context.delete(item)
        }
    }

    private func clearDeviceSnapshots(groupId: String) throws {
        for item in try context.fetch(FetchDescriptor<WaterControlDeviceSnapshot>()) where item.groupId == groupId {
            context.delete(item)
        }
    }

    private func notifyDataDidChange() {
        NotificationCenter.default.post(name: .waterControlDataDidChange, object: nil)
    }
}
