import Foundation
import SwiftData

@MainActor
public final class LibrarySpaceStore: ObservableObject {
    @Published public private(set) var libraries: [LibrarySpaceLibrary] = []
    @Published public private(set) var areas: [LibrarySpaceArea] = []
    @Published public private(set) var rooms: [LibrarySpaceRoom] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSyncTime: Date?

    private let context: ModelContext
    private let api: LibrarySpaceAPI
    private static var overviewTask: Task<LibrarySpaceOverviewResult, Error>?

    public init(modelContext: ModelContext, api: LibrarySpaceAPI = LibrarySpaceAPI()) {
        self.context = modelContext
        self.api = api
        loadFromLocal()
    }

    public var targetLibraries: [LibrarySpaceLibrary] {
        let targetSet = Set(LibrarySpaceConstants.targetLibraryNames)
        return libraries
            .filter { targetSet.contains($0.name) }
            .sorted { lhs, rhs in
                guard let lhsIndex = LibrarySpaceConstants.targetLibraryNames.firstIndex(of: lhs.name),
                      let rhsIndex = LibrarySpaceConstants.targetLibraryNames.firstIndex(of: rhs.name) else {
                    return lhs.name < rhs.name
                }
                return lhsIndex < rhsIndex
            }
    }

    public var otherLibraries: [LibrarySpaceLibrary] {
        libraries.filter { !$0.isTargetLibrary }.sorted { $0.name < $1.name }
    }

    public func areas(in library: LibrarySpaceLibrary) -> [LibrarySpaceArea] {
        areas
            .filter { $0.libraryId == library.id || $0.libraryName == library.name }
            .sorted { lhs, rhs in
                if lhs.floorName == rhs.floorName {
                    return lhs.name < rhs.name
                }
                return lhs.floorName.localizedStandardCompare(rhs.floorName) == .orderedAscending
            }
    }

    public func rooms(in library: LibrarySpaceLibrary) -> [LibrarySpaceRoom] {
        rooms
            .filter { $0.libraryId == library.id || $0.libraryName == library.name }
            .sorted { lhs, rhs in
                let floorOrder = Self.compareNatural(lhs.floorName, rhs.floorName)
                if floorOrder != .orderedSame {
                    return floorOrder == .orderedAscending
                }

                let nameOrder = Self.compareNatural(lhs.name, rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }

                let lhsNumber = Self.firstNumber(in: "\(lhs.name) \(lhs.mergedName) \(lhs.id)")
                let rhsNumber = Self.firstNumber(in: "\(rhs.name) \(rhs.mergedName) \(rhs.id)")
                if let lhsNumber, let rhsNumber, lhsNumber != rhsNumber {
                    return lhsNumber < rhsNumber
                }

                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
    }

    private static func compareNatural(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }

    private static func firstNumber(in value: String) -> Int? {
        var digits = ""
        for character in value {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    public func loadFromLocal() {
        do {
            let overviewSnapshots = try context.fetch(
                FetchDescriptor<LibrarySpaceOverviewSnapshot>(
                    sortBy: [SortDescriptor(\.name)]
                )
            )
            libraries = overviewSnapshots
                .map { $0.asLibrary() }
                .sorted { lhs, rhs in
                    if lhs.isTargetLibrary != rhs.isTargetLibrary {
                        return lhs.isTargetLibrary
                    }
                    return lhs.name < rhs.name
                }
            lastSyncTime = overviewSnapshots.map { $0.syncTime }.max()

            let areaSnapshots = try context.fetch(
                FetchDescriptor<LibrarySpaceAreaSnapshot>(
                    sortBy: [SortDescriptor(\.libraryName), SortDescriptor(\.floorName), SortDescriptor(\.name)]
                )
            )
            areas = areaSnapshots.map { $0.asArea() }

            let roomSnapshots = try context.fetch(
                FetchDescriptor<LibrarySpaceRoomSnapshot>(
                    sortBy: [SortDescriptor(\.libraryName), SortDescriptor(\.floorName), SortDescriptor(\.name)]
                )
            )
            rooms = roomSnapshots.map { $0.asRoom() }
        } catch {
            libraries = []
            areas = []
            rooms = []
            lastSyncTime = nil
            lastError = error.localizedDescription
        }
    }

    public func sync(force: Bool = false) async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        do {
            let result = try await sharedOverviewResult(force: force)
            let syncTime = Date()
            try clearAll()

            for library in result.libraries {
                context.insert(
                    LibrarySpaceOverviewSnapshot(
                        libraryId: library.id,
                        name: library.name,
                        totalSeats: library.totalSeats,
                        freeSeats: library.freeSeats,
                        isTargetLibrary: library.isTargetLibrary,
                        syncTime: syncTime
                    )
                )
            }

            for area in result.areas {
                context.insert(
                    LibrarySpaceAreaSnapshot(
                        areaId: area.id,
                        libraryId: area.libraryId,
                        libraryName: area.libraryName,
                        floorId: area.floorId,
                        floorName: area.floorName,
                        name: area.name,
                        mergedName: area.mergedName,
                        typeName: area.typeName,
                        totalSeats: area.totalSeats,
                        freeSeats: area.freeSeats,
                        syncTime: syncTime
                    )
                )
            }

            for room in result.rooms {
                context.insert(
                    LibrarySpaceRoomSnapshot(
                        roomId: room.id,
                        libraryId: room.libraryId,
                        libraryName: room.libraryName,
                        floorId: room.floorId,
                        floorName: room.floorName,
                        name: room.name,
                        mergedName: room.mergedName,
                        typeName: room.typeName,
                        syncTime: syncTime
                    )
                )
            }

            try context.save()
            loadFromLocal()
        } catch let error as AuthError {
            lastError = error.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sharedOverviewResult(force: Bool) async throws -> LibrarySpaceOverviewResult {
        if let task = Self.overviewTask {
            return try await task.value
        }

        let task = Task { [api] in
            try await api.fetchOverview(force: force)
        }
        Self.overviewTask = task
        defer { Self.overviewTask = nil }
        return try await task.value
    }

    public func clearError() {
        lastError = nil
    }

    public func clearLocalData() {
        do {
            try clearAll()
            try context.save()
            libraries = []
            areas = []
            rooms = []
            lastSyncTime = nil
            lastError = nil
            LibrarySpaceAuthCoordinator.shared.clearToken()
        } catch {
            libraries = []
            areas = []
            rooms = []
            lastError = error.localizedDescription
        }
    }

    private func clearAll() throws {
        for item in try context.fetch(FetchDescriptor<LibrarySpaceOverviewSnapshot>()) {
            context.delete(item)
        }
        for item in try context.fetch(FetchDescriptor<LibrarySpaceAreaSnapshot>()) {
            context.delete(item)
        }
        for item in try context.fetch(FetchDescriptor<LibrarySpaceRoomSnapshot>()) {
            context.delete(item)
        }
    }
}
