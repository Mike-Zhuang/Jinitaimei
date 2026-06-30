import Foundation
import SwiftData

@MainActor
public final class LaundryStore: ObservableObject, CampusLocalStore {
    @Published public private(set) var rooms: [LaundryRoom] = []
    @Published public private(set) var machinesByRoom: [String: [LaundryMachine]] = [:]
    @Published public private(set) var isLoadingRooms = false
    @Published public private(set) var loadingRoomIds: Set<String> = []
    @Published public private(set) var roomErrors: [String: String] = [:]
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSyncTime: Date?

    private let context: ModelContext
    private let api: LaundryAPI
    private static var roomsTask: Task<[LaundryRoom], Error>?

    public init(modelContext: ModelContext, api: LaundryAPI = LaundryAPI()) {
        self.context = modelContext
        self.api = api
        loadFromLocal()
    }

    public func machines(for room: LaundryRoom) -> [LaundryMachine] {
        machinesByRoom[room.id] ?? []
    }

    public func error(for room: LaundryRoom) -> String? {
        roomErrors[room.id]
    }

    public func room(id: String) -> LaundryRoom? {
        rooms.first { $0.id == id }
    }

    public func syncRooms(force: Bool = false) async {
        if isLoadingRooms { return }
        isLoadingRooms = true
        defer { isLoadingRooms = false }
        clearError()

        do {
            let remoteRooms = try await sharedRooms(force: force)
            let syncTime = Date()
            try clearRoomSnapshots()
            for room in remoteRooms {
                context.insert(LaundryRoomSnapshot(
                    roomId: room.id,
                    rawName: room.rawName,
                    rawAddress: room.rawAddress,
                    washingMachineCount: room.washingMachineCount,
                    dryerCount: room.dryerCount,
                    distance: room.distance,
                    distanceMessage: room.distanceMessage,
                    syncTime: syncTime
                ))
            }
            try context.save()
            loadFromLocal()
            notifyDataDidChange()
        } catch {
            record(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func syncMachines(for room: LaundryRoom, force: Bool = false) async {
        if loadingRoomIds.contains(room.id) { return }
        if !force, machinesByRoom[room.id]?.isEmpty == false { return }
        if !force, roomErrors[room.id] != nil { return }

        loadingRoomIds.insert(room.id)
        defer { loadingRoomIds.remove(room.id) }
        setRoomError(nil, roomId: room.id)

        do {
            let machines = try await api.fetchMachines(for: room)
            let syncTime = Date()
            try clearMachineSnapshots(roomId: room.id)
            for machine in machines {
                context.insert(LaundryMachineSnapshot(
                    machineId: machine.id,
                    roomId: machine.roomId,
                    roomName: machine.roomName,
                    machineSn: machine.machineSn,
                    machineTypeName: machine.machineTypeName,
                    isOnline: machine.isOnline,
                    runningStatus: machine.runningStatus,
                    runningProgram: machine.runningProgram,
                    runningStatusDescription: machine.runningStatusDescription,
                    appointmentStatus: machine.appointmentStatus,
                    remainingMinutes: machine.remainingMinutes,
                    isOnlineMachine: machine.isOnlineMachine,
                    syncTime: syncTime
                ))
            }
            try context.save()
            loadFromLocal()
            notifyDataDidChange()
        } catch {
            setRoomError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, roomId: room.id)
        }
    }

    public func syncPinnedRoom(id: String, force: Bool = false) async {
        if rooms.isEmpty {
            await syncRooms(force: force)
        }
        guard let room = room(id: id) else { return }
        await syncMachines(for: room, force: force)
    }

    public func loadFromLocal() {
        do {
            let roomSnapshots = try context.fetch(
                FetchDescriptor<LaundryRoomSnapshot>()
            )
            rooms = roomSnapshots
                .map { $0.asRoom() }
                .sorted(by: Self.roomSort)

            let machineSnapshots = try context.fetch(
                FetchDescriptor<LaundryMachineSnapshot>(
                    sortBy: [SortDescriptor(\.roomName), SortDescriptor(\.machineSn)]
                )
            )
            let machines = machineSnapshots.map { $0.asMachine() }
            machinesByRoom = Dictionary(grouping: machines, by: \.roomId)
            lastSyncTime = (roomSnapshots.map { $0.syncTime } + machineSnapshots.map { $0.syncTime }).max()
        } catch {
            rooms = []
            machinesByRoom = [:]
            roomErrors = [:]
            lastSyncTime = nil
            lastError = error.localizedDescription
        }
    }

    public func clearError() {
        lastError = nil
        roomErrors = [:]
    }

    public func clearRemoteSession() {
        api.clearSession()
        clearError()
    }

    public func clearLocalData() {
        do {
            try clearRoomSnapshots()
            for item in try context.fetch(FetchDescriptor<LaundryMachineSnapshot>()) {
                context.delete(item)
            }
            try context.save()
        } catch {
            record(message: error.localizedDescription)
        }
        rooms = []
        machinesByRoom = [:]
        roomErrors = [:]
        lastSyncTime = nil
        UserDefaults.standard.removeObject(forKey: LaundryPreferences.pinnedRoomIdKey)
        notifyDataDidChange()
    }

    private func record(message: String) {
        lastError = message
    }

    private func setRoomError(_ message: String?, roomId: String) {
        var next = roomErrors
        next[roomId] = message
        roomErrors = next
    }

    private func sharedRooms(force: Bool) async throws -> [LaundryRoom] {
        if let task = Self.roomsTask {
            return try await task.value
        }
        let task = Task { [api] in
            try await api.fetchRooms()
        }
        Self.roomsTask = task
        defer { Self.roomsTask = nil }
        return try await task.value
    }

    private func clearRoomSnapshots() throws {
        for item in try context.fetch(FetchDescriptor<LaundryRoomSnapshot>()) {
            context.delete(item)
        }
    }

    private func clearMachineSnapshots(roomId: String) throws {
        for item in try context.fetch(FetchDescriptor<LaundryMachineSnapshot>()) where item.roomId == roomId {
            context.delete(item)
        }
    }

    private func notifyDataDidChange() {
        NotificationCenter.default.post(name: .laundryDataDidChange, object: nil)
    }

    private static func roomSort(_ lhs: LaundryRoom, _ rhs: LaundryRoom) -> Bool {
        switch (lhs.distance, rhs.distance) {
        case let (l?, r?) where l != r:
            return l < r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}
