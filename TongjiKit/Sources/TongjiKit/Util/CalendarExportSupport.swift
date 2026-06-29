import EventKit
import Foundation

enum CalendarExportSupport {
    private static let markerPrefix = "JinitaimeiExportID: "

    static func stableID(kind: String, components: [String]) -> String {
        let body = components.map(normalized).joined(separator: "|")
        return "jinitaimei-\(kind)-v1-\(fnv1a64(body))"
    }

    static func notes(lines: [String?], exportID: String) -> String {
        let visibleLines = lines
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (visibleLines + [markerLine(for: exportID)]).joined(separator: "\n")
    }

    static func exportURL(for exportID: String) -> URL? {
        URL(string: "jinitaimei://calendar-export/\(exportID)")
    }

    static func removeExistingEvents(
        eventStore: EKEventStore,
        calendar: EKCalendar,
        range: DateInterval,
        exportID: String,
        legacyMatches: (EKEvent) -> Bool
    ) throws {
        let predicate = eventStore.predicateForEvents(
            withStart: range.start,
            end: range.end,
            calendars: [calendar]
        )
        let matchedEvents = eventStore.events(matching: predicate)
            .filter { matchesExportID($0, exportID: exportID) || legacyMatches($0) }
            .sorted { $0.startDate < $1.startDate }

        var removedIdentifiers = Set<String>()
        for event in matchedEvents {
            let identifier = event.calendarItemIdentifier
            guard removedIdentifiers.insert(identifier).inserted else { continue }
            let span: EKSpan = (event.recurrenceRules?.isEmpty == false) ? .futureEvents : .thisEvent
            try eventStore.remove(event, span: span, commit: false)
        }
    }

    static func matchesTime(_ event: EKEvent, expectedRanges: [(Date, Date)]) -> Bool {
        expectedRanges.contains { expectedStart, expectedEnd in
            datesAreClose(event.startDate, expectedStart) && datesAreClose(event.endDate, expectedEnd)
        }
    }

    static func text(_ lhs: String?, equals rhs: String) -> Bool {
        normalized(lhs ?? "") == normalized(rhs)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchesExportID(_ event: EKEvent, exportID: String) -> Bool {
        if event.url == exportURL(for: exportID) {
            return true
        }
        return event.notes?.contains(markerLine(for: exportID)) == true
    }

    private static func markerLine(for exportID: String) -> String {
        "\(markerPrefix)\(exportID)"
    }

    private static func datesAreClose(_ lhs: Date?, _ rhs: Date, tolerance: TimeInterval = 60) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= tolerance
    }

    private static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
