import Foundation
import SwiftData

public enum LibrarySpaceConstants {
    public static let targetLibraryNames = [
        "四平路校区图书馆",
        "德文图书馆",
        "东区图书馆",
        "嘉定校区图书馆"
    ]

    public static let localSingleSeatTag = "单人单座"
}

@Model
public final class LibrarySpaceOverviewSnapshot {
    public var libraryId: String = ""
    public var name: String = ""
    public var totalSeats: Int = 0
    public var freeSeats: Int = 0
    public var isTargetLibrary: Bool = false
    public var syncTime: Date = Date()

    public init(
        libraryId: String,
        name: String,
        totalSeats: Int,
        freeSeats: Int,
        isTargetLibrary: Bool,
        syncTime: Date
    ) {
        self.libraryId = libraryId
        self.name = name
        self.totalSeats = totalSeats
        self.freeSeats = freeSeats
        self.isTargetLibrary = isTargetLibrary
        self.syncTime = syncTime
    }

    public var usedSeats: Int {
        max(totalSeats - freeSeats, 0)
    }

    public var freeRatio: Double {
        guard totalSeats > 0 else { return 0 }
        return Double(freeSeats) / Double(totalSeats)
    }
}

@Model
public final class LibrarySpaceAreaSnapshot {
    public var areaId: String = ""
    public var libraryId: String = ""
    public var libraryName: String = ""
    public var floorId: String = ""
    public var floorName: String = ""
    public var name: String = ""
    public var mergedName: String = ""
    public var typeName: String = ""
    public var totalSeats: Int = 0
    public var freeSeats: Int = 0
    public var syncTime: Date = Date()

    public init(
        areaId: String,
        libraryId: String,
        libraryName: String,
        floorId: String,
        floorName: String,
        name: String,
        mergedName: String,
        typeName: String,
        totalSeats: Int,
        freeSeats: Int,
        syncTime: Date
    ) {
        self.areaId = areaId
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.floorId = floorId
        self.floorName = floorName
        self.name = name
        self.mergedName = mergedName
        self.typeName = typeName
        self.totalSeats = totalSeats
        self.freeSeats = freeSeats
        self.syncTime = syncTime
    }

    public var freeRatio: Double {
        guard totalSeats > 0 else { return 0 }
        return Double(freeSeats) / Double(totalSeats)
    }
}

@Model
public final class LibrarySpaceRoomSnapshot {
    public var roomId: String = ""
    public var libraryId: String = ""
    public var libraryName: String = ""
    public var floorId: String = ""
    public var floorName: String = ""
    public var name: String = ""
    public var mergedName: String = ""
    public var typeName: String = ""
    public var syncTime: Date = Date()

    public init(
        roomId: String,
        libraryId: String,
        libraryName: String,
        floorId: String,
        floorName: String,
        name: String,
        mergedName: String,
        typeName: String,
        syncTime: Date
    ) {
        self.roomId = roomId
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.floorId = floorId
        self.floorName = floorName
        self.name = name
        self.mergedName = mergedName
        self.typeName = typeName
        self.syncTime = syncTime
    }
}

public struct LibrarySpaceOverviewResult: Sendable {
    public let libraries: [LibrarySpaceLibrary]
    public let areas: [LibrarySpaceArea]
    public let rooms: [LibrarySpaceRoom]
}

public struct LibrarySpaceLibrary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let totalSeats: Int
    public let freeSeats: Int

    public var usedSeats: Int { max(totalSeats - freeSeats, 0) }
    public var freeRatio: Double {
        guard totalSeats > 0 else { return 0 }
        return Double(freeSeats) / Double(totalSeats)
    }

    public var isTargetLibrary: Bool {
        LibrarySpaceConstants.targetLibraryNames.contains(name)
    }
}

public struct LibrarySpaceArea: Identifiable, Hashable, Sendable {
    public let id: String
    public let libraryId: String
    public let libraryName: String
    public let floorId: String
    public let floorName: String
    public let name: String
    public let mergedName: String
    public let typeName: String
    public let totalSeats: Int
    public let freeSeats: Int

    public var freeRatio: Double {
        guard totalSeats > 0 else { return 0 }
        return Double(freeSeats) / Double(totalSeats)
    }
}

public struct LibrarySpaceRoom: Identifiable, Hashable, Sendable {
    public let id: String
    public let libraryId: String
    public let libraryName: String
    public let floorId: String
    public let floorName: String
    public let name: String
    public let mergedName: String
    public let typeName: String
}

public struct LibrarySeatLabel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public struct LibrarySeatTimeSegment: Identifiable, Hashable, Sendable {
    public let id: String
    public let day: String
    public let startTime: String
    public let endTime: String
}

public struct LibrarySeat: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: String
    public let name: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let status: String
    public let statusName: String
    public let areaName: String
    public let labels: [String]

    public var isFree: Bool {
        status == "1" || statusName.contains("空闲")
    }
}

public struct LibrarySeatMapAssets: Sendable {
    public let freeURL: URL?
    public let useURL: URL?
    public let leaveURL: URL?
    public let bookURL: URL?
    public let closeURL: URL?
    public let notURL: URL?
    public let configURL: URL?
}

public struct LibrarySeatAreaDetail: Sendable {
    public let area: LibrarySpaceArea
    public let labels: [LibrarySeatLabel]
    public let mapAssets: LibrarySeatMapAssets
    public let segments: [LibrarySeatTimeSegment]
    public let seats: [LibrarySeat]
}

public struct LibrarySeminarRoomAvailability: Identifiable, Sendable {
    public let id: String
    public let roomId: String
    public let date: String
    public let openStartMinute: Int
    public let openEndMinute: Int
    public let minMinutes: Int
    public let maxMinutes: Int
    public let minPeople: Int
    public let maxPeople: Int
    public let freeSegments: [LibrarySeminarFreeSegment]
}

public struct LibrarySeminarFreeSegment: Identifiable, Hashable, Sendable {
    public let id: String
    public let beginText: String
    public let endText: String
    public let beginMinute: Int
    public let endMinute: Int
}

public struct LibrarySeminarRoomDetail: Sendable {
    public let room: LibrarySpaceRoom
    public let memberCountText: String
    public let minPeople: Int
    public let maxPeople: Int
    public let availabilities: [LibrarySeminarRoomAvailability]
}

extension LibrarySpaceOverviewSnapshot {
    public func asLibrary() -> LibrarySpaceLibrary {
        LibrarySpaceLibrary(id: libraryId, name: name, totalSeats: totalSeats, freeSeats: freeSeats)
    }
}

extension LibrarySpaceAreaSnapshot {
    public func asArea() -> LibrarySpaceArea {
        LibrarySpaceArea(
            id: areaId,
            libraryId: libraryId,
            libraryName: libraryName,
            floorId: floorId,
            floorName: floorName,
            name: name,
            mergedName: mergedName,
            typeName: typeName,
            totalSeats: totalSeats,
            freeSeats: freeSeats
        )
    }
}

extension LibrarySpaceRoomSnapshot {
    public func asRoom() -> LibrarySpaceRoom {
        LibrarySpaceRoom(
            id: roomId,
            libraryId: libraryId,
            libraryName: libraryName,
            floorId: floorId,
            floorName: floorName,
            name: name,
            mergedName: mergedName,
            typeName: typeName
        )
    }
}
