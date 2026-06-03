import Foundation

public enum LibrarySeatLocalTagger {
    public static func tags(for seat: LibrarySeat, in area: LibrarySpaceArea) -> [String] {
        var result: [String] = []
        if isSingleSeat(seatNumber: seat.number, area: area) {
            result.append(LibrarySpaceConstants.localSingleSeatTag)
        }
        return result
    }

    public static func isSingleSeat(seatNumber: String, area: LibrarySpaceArea) -> Bool {
        guard let number = Int(seatNumber.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }

        let library = area.libraryName
        let haystack = "\(area.floorName)-\(area.name)-\(area.mergedName)"

        if library.contains("四平路") {
            if haystack.contains("二楼") {
                return (113...128).contains(number) || (191...214).contains(number)
            }

            let isTargetFloor = haystack.contains("六楼") ||
                                haystack.contains("6楼") ||
                                haystack.contains("八楼") ||
                                haystack.contains("8楼") ||
                                haystack.contains("十楼") ||
                                haystack.contains("10楼")
            let isNorthOrSouth = haystack.contains("南") || haystack.contains("北")
            if isTargetFloor, isNorthOrSouth {
                return (1...7).contains(number) ||
                       (32...40).contains(number) ||
                       (73...81).contains(number)
            }
        }

        if library.contains("东区") {
            if haystack.contains("二楼") {
                return (57...69).contains(number)
            }
            if haystack.contains("三楼") {
                return (65...79).contains(number)
            }
        }

        return false
    }
}
