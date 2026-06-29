import Foundation
import SwiftData

public enum WaterControlStatus: Int, Codable, Sendable, CaseIterable {
    case offline = 0
    case available = 1
    case locked = 2
    case alarm = 3
    case inUse = 4
    case unknown = -1

    public init(code: Int?) {
        guard let code, let value = WaterControlStatus(rawValue: code) else {
            self = .unknown
            return
        }
        self = value
    }

    public var title: String {
        switch self {
        case .offline: "离线"
        case .available: "空闲"
        case .locked: "加锁"
        case .alarm: "报警"
        case .inUse: "使用中"
        case .unknown: "未知"
        }
    }

    public var isProblematic: Bool {
        self == .offline || self == .locked || self == .alarm || self == .unknown
    }
}

public struct WaterControlAuthParams: Sendable, Equatable {
    public let account: String
    public let aesKey: String
    public let password: String

    public init(account: String, aesKey: String, password: String) {
        self.account = account
        self.aesKey = aesKey
        self.password = password
    }
}

public struct WaterControlGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let posNum: Int?
    public let warnPosNum: Int?
    public let useFreeRate: String?
    public let bookRate: String?
    public let actkind: String?
    public let bookCode: String?

    public init(
        id: String,
        name: String,
        posNum: Int?,
        warnPosNum: Int?,
        useFreeRate: String?,
        bookRate: String?,
        actkind: String?,
        bookCode: String?
    ) {
        self.id = id
        self.name = name
        self.posNum = posNum
        self.warnPosNum = warnPosNum
        self.useFreeRate = useFreeRate
        self.bookRate = bookRate
        self.actkind = actkind
        self.bookCode = bookCode
    }
}

public struct WaterControlDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let groupId: String
    public let groupName: String
    public let name: String
    public let posNum: Int?
    public let warnPosNum: Int?
    public let useFreeRate: String?
    public let bookRate: String?
    public let actkind: String?
    public let bookCode: String?

    public init(
        id: String,
        groupId: String,
        groupName: String,
        name: String,
        posNum: Int?,
        warnPosNum: Int?,
        useFreeRate: String?,
        bookRate: String?,
        actkind: String?,
        bookCode: String?
    ) {
        self.id = id
        self.groupId = groupId
        self.groupName = groupName
        self.name = name
        self.posNum = posNum
        self.warnPosNum = warnPosNum
        self.useFreeRate = useFreeRate
        self.bookRate = bookRate
        self.actkind = actkind
        self.bookCode = bookCode
    }

    public var status: WaterControlStatus {
        WaterControlStatus(code: posNum)
    }
}

public struct WaterControlSummary: Sendable, Equatable {
    public let totalDevices: Int
    public let availableCount: Int
    public let inUseCount: Int
    public let problemCount: Int

    public init(devices: [WaterControlDevice]) {
        totalDevices = devices.count
        availableCount = devices.filter { $0.status == .available }.count
        inUseCount = devices.filter { $0.status == .inUse }.count
        problemCount = devices.filter { $0.status.isProblematic }.count
    }
}

@Model
public final class WaterControlGroupSnapshot {
    public var groupId: String = ""
    public var name: String = ""
    public var posNum: Int?
    public var warnPosNum: Int?
    public var useFreeRate: String?
    public var bookRate: String?
    public var actkind: String?
    public var bookCode: String?
    public var syncTime: Date = Date()

    public init(
        groupId: String,
        name: String,
        posNum: Int?,
        warnPosNum: Int?,
        useFreeRate: String?,
        bookRate: String?,
        actkind: String?,
        bookCode: String?,
        syncTime: Date
    ) {
        self.groupId = groupId
        self.name = name
        self.posNum = posNum
        self.warnPosNum = warnPosNum
        self.useFreeRate = useFreeRate
        self.bookRate = bookRate
        self.actkind = actkind
        self.bookCode = bookCode
        self.syncTime = syncTime
    }
}

@Model
public final class WaterControlDeviceSnapshot {
    public var deviceId: String = ""
    public var groupId: String = ""
    public var groupName: String = ""
    public var name: String = ""
    public var posNum: Int?
    public var warnPosNum: Int?
    public var useFreeRate: String?
    public var bookRate: String?
    public var actkind: String?
    public var bookCode: String?
    public var syncTime: Date = Date()

    public init(
        deviceId: String,
        groupId: String,
        groupName: String,
        name: String,
        posNum: Int?,
        warnPosNum: Int?,
        useFreeRate: String?,
        bookRate: String?,
        actkind: String?,
        bookCode: String?,
        syncTime: Date
    ) {
        self.deviceId = deviceId
        self.groupId = groupId
        self.groupName = groupName
        self.name = name
        self.posNum = posNum
        self.warnPosNum = warnPosNum
        self.useFreeRate = useFreeRate
        self.bookRate = bookRate
        self.actkind = actkind
        self.bookCode = bookCode
        self.syncTime = syncTime
    }
}

public extension WaterControlGroupSnapshot {
    func asGroup() -> WaterControlGroup {
        WaterControlGroup(
            id: groupId,
            name: name,
            posNum: posNum,
            warnPosNum: warnPosNum,
            useFreeRate: useFreeRate,
            bookRate: bookRate,
            actkind: actkind,
            bookCode: bookCode
        )
    }
}

public extension WaterControlDeviceSnapshot {
    func asDevice() -> WaterControlDevice {
        WaterControlDevice(
            id: deviceId,
            groupId: groupId,
            groupName: groupName,
            name: name,
            posNum: posNum,
            warnPosNum: warnPosNum,
            useFreeRate: useFreeRate,
            bookRate: bookRate,
            actkind: actkind,
            bookCode: bookCode
        )
    }
}
