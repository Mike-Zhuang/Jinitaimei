import Foundation
import SwiftData

public enum LaundryMachineStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case offline
    case unknown

    public init(isOnline: Bool?, runningStatus: Int?, description: String?) {
        if isOnline == false {
            self = .offline
            return
        }
        let text = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.contains("空闲") || runningStatus == 1 {
            self = .idle
        } else if text.contains("运行") || runningStatus == 2 {
            self = .running
        } else {
            self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .idle: "空闲"
        case .running: "运行中"
        case .offline: "离线"
        case .unknown: "未知"
        }
    }
}

public struct LaundryRoom: Identifiable, Hashable, Sendable {
    public let id: String
    public let rawName: String
    public let rawAddress: String
    public let washingMachineCount: Int
    public let dryerCount: Int
    public let distance: Int?
    public let distanceMessage: String?

    public init(
        id: String,
        rawName: String,
        rawAddress: String,
        washingMachineCount: Int,
        dryerCount: Int,
        distance: Int?,
        distanceMessage: String?
    ) {
        self.id = id
        self.rawName = rawName
        self.rawAddress = rawAddress
        self.washingMachineCount = washingMachineCount
        self.dryerCount = dryerCount
        self.distance = distance
        self.distanceMessage = distanceMessage
    }

    public var displayName: String {
        rawName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "未知洗衣房"
    }
}

public struct LaundryMachine: Identifiable, Hashable, Sendable {
    public let id: String
    public let roomId: String
    public let roomName: String
    public let machineSn: String
    public let machineTypeName: String
    public let isOnline: Bool?
    public let runningStatus: Int?
    public let runningProgram: Int?
    public let runningStatusDescription: String?
    public let appointmentStatus: Bool?
    public let remainingMinutes: Int?
    public let isOnlineMachine: Bool?

    public init(
        id: String,
        roomId: String,
        roomName: String,
        machineSn: String,
        machineTypeName: String,
        isOnline: Bool?,
        runningStatus: Int?,
        runningProgram: Int?,
        runningStatusDescription: String?,
        appointmentStatus: Bool?,
        remainingMinutes: Int?,
        isOnlineMachine: Bool?
    ) {
        self.id = id
        self.roomId = roomId
        self.roomName = roomName
        self.machineSn = machineSn
        self.machineTypeName = machineTypeName
        self.isOnline = isOnline
        self.runningStatus = runningStatus
        self.runningProgram = runningProgram
        self.runningStatusDescription = runningStatusDescription
        self.appointmentStatus = appointmentStatus
        self.remainingMinutes = remainingMinutes
        self.isOnlineMachine = isOnlineMachine
    }

    public var status: LaundryMachineStatus {
        LaundryMachineStatus(
            isOnline: isOnline,
            runningStatus: runningStatus,
            description: runningStatusDescription
        )
    }
}

public struct LaundryMachineSummary: Sendable, Equatable {
    public let totalCount: Int
    public let idleCount: Int
    public let runningCount: Int
    public let offlineCount: Int
    public let unknownCount: Int

    public init(machines: [LaundryMachine]) {
        totalCount = machines.count
        idleCount = machines.filter { $0.status == .idle }.count
        runningCount = machines.filter { $0.status == .running }.count
        offlineCount = machines.filter { $0.status == .offline }.count
        unknownCount = machines.filter { $0.status == .unknown }.count
    }
}

@Model
public final class LaundryRoomSnapshot {
    public var roomId: String = ""
    public var rawName: String = ""
    public var rawAddress: String = ""
    public var washingMachineCount: Int = 0
    public var dryerCount: Int = 0
    public var distance: Int?
    public var distanceMessage: String?
    public var syncTime: Date = Date()

    public init(
        roomId: String,
        rawName: String,
        rawAddress: String,
        washingMachineCount: Int,
        dryerCount: Int,
        distance: Int?,
        distanceMessage: String?,
        syncTime: Date
    ) {
        self.roomId = roomId
        self.rawName = rawName
        self.rawAddress = rawAddress
        self.washingMachineCount = washingMachineCount
        self.dryerCount = dryerCount
        self.distance = distance
        self.distanceMessage = distanceMessage
        self.syncTime = syncTime
    }
}

@Model
public final class LaundryMachineSnapshot {
    public var machineId: String = ""
    public var roomId: String = ""
    public var roomName: String = ""
    public var machineSn: String = ""
    public var machineTypeName: String = ""
    public var isOnline: Bool?
    public var runningStatus: Int?
    public var runningProgram: Int?
    public var runningStatusDescription: String?
    public var appointmentStatus: Bool?
    public var remainingMinutes: Int?
    public var isOnlineMachine: Bool?
    public var syncTime: Date = Date()

    public init(
        machineId: String,
        roomId: String,
        roomName: String,
        machineSn: String,
        machineTypeName: String,
        isOnline: Bool?,
        runningStatus: Int?,
        runningProgram: Int?,
        runningStatusDescription: String?,
        appointmentStatus: Bool?,
        remainingMinutes: Int?,
        isOnlineMachine: Bool?,
        syncTime: Date
    ) {
        self.machineId = machineId
        self.roomId = roomId
        self.roomName = roomName
        self.machineSn = machineSn
        self.machineTypeName = machineTypeName
        self.isOnline = isOnline
        self.runningStatus = runningStatus
        self.runningProgram = runningProgram
        self.runningStatusDescription = runningStatusDescription
        self.appointmentStatus = appointmentStatus
        self.remainingMinutes = remainingMinutes
        self.isOnlineMachine = isOnlineMachine
        self.syncTime = syncTime
    }
}

public extension LaundryRoomSnapshot {
    func asRoom() -> LaundryRoom {
        LaundryRoom(
            id: roomId,
            rawName: rawName,
            rawAddress: rawAddress,
            washingMachineCount: washingMachineCount,
            dryerCount: dryerCount,
            distance: distance,
            distanceMessage: distanceMessage
        )
    }
}

public extension LaundryMachineSnapshot {
    func asMachine() -> LaundryMachine {
        LaundryMachine(
            id: machineId,
            roomId: roomId,
            roomName: roomName,
            machineSn: machineSn,
            machineTypeName: machineTypeName,
            isOnline: isOnline,
            runningStatus: runningStatus,
            runningProgram: runningProgram,
            runningStatusDescription: runningStatusDescription,
            appointmentStatus: appointmentStatus,
            remainingMinutes: remainingMinutes,
            isOnlineMachine: isOnlineMachine
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
