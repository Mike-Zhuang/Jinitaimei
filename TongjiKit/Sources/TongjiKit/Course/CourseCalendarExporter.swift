import Foundation
import EventKit

public struct CourseExportKey: Identifiable, Hashable, Sendable {
    public var id: String {
        [
            courseName,
            teacher,
            location,
            String(dayOfWeek),
            String(startPeriod),
            String(endPeriod)
        ].joined(separator: "|")
    }

    public let courseName: String
    public let teacher: String
    public let location: String
    public let dayOfWeek: Int
    public let startPeriod: Int
    public let endPeriod: Int

    public init(course: CourseSchedule) {
        self.courseName = course.courseName
        self.teacher = course.teacher
        self.location = course.location
        self.dayOfWeek = course.dayOfWeek
        self.startPeriod = course.startPeriod
        self.endPeriod = course.endPeriod
    }
}

public enum CourseCalendarExporter {
    public static func calendarMap(for schedules: [CourseSchedule]) -> [CourseExportKey: [CourseSchedule]] {
        var map: [CourseExportKey: [CourseSchedule]] = [:]
        for schedule in schedules {
            map[CourseExportKey(course: schedule), default: []].append(schedule)
        }
        return map
    }

    public static func export(
        schedules: [CourseSchedule],
        selectedKeys: Set<CourseExportKey>,
        semesterStart: Date,
        to calendar: EKCalendar,
        eventStore: EKEventStore,
        alarmOffsetsMinutes: Set<Int> = []
    ) throws {
        let map = calendarMap(for: schedules)
        for key in selectedKeys {
            guard let courses = map[key] else { continue }
            try export(
                courses: courses,
                key: key,
                semesterStart: semesterStart,
                to: calendar,
                eventStore: eventStore,
                alarmOffsetsMinutes: alarmOffsetsMinutes
            )
        }
        try eventStore.commit()
    }

    private static func export(
        courses: [CourseSchedule],
        key: CourseExportKey,
        semesterStart: Date,
        to calendar: EKCalendar,
        eventStore: EKEventStore,
        alarmOffsetsMinutes: Set<Int>
    ) throws {
        let weeks = Array(Set(courses.map(\.weekNumber))).sorted()
        guard let firstWeek = weeks.first else { return }
        let exportID = exportID(for: courses, key: key, weeks: weeks, semesterStart: semesterStart)
        let expectedRanges = weeks.map { computeTime(for: key, week: $0, semesterStart: semesterStart) }
        try CalendarExportSupport.removeExistingEvents(
            eventStore: eventStore,
            calendar: calendar,
            range: searchRange(for: expectedRanges),
            exportID: exportID
        ) { event in
            legacyEvent(event, matches: key, expectedRanges: expectedRanges)
        }

        if let interval = recurrenceInterval(for: weeks) {
            let event = makeEvent(
                key: key,
                weekText: courses.first?.weekText,
                week: firstWeek,
                semesterStart: semesterStart,
                exportID: exportID,
                calendar: calendar,
                eventStore: eventStore,
                alarmOffsetsMinutes: alarmOffsetsMinutes
            )
            event.addRecurrenceRule(
                EKRecurrenceRule(
                    recurrenceWith: .weekly,
                    interval: interval,
                    end: EKRecurrenceEnd(occurrenceCount: ((weeks.last ?? firstWeek) - firstWeek) / interval + 1)
                )
            )
            try eventStore.save(event, span: .thisEvent, commit: false)
        } else {
            for week in weeks {
                let event = makeEvent(
                    key: key,
                    weekText: courses.first?.weekText,
                    week: week,
                    semesterStart: semesterStart,
                    exportID: exportID,
                    calendar: calendar,
                    eventStore: eventStore,
                    alarmOffsetsMinutes: alarmOffsetsMinutes
                )
                try eventStore.save(event, span: .thisEvent, commit: false)
            }
        }
    }

    /// 只有严格连续的每周/单双周才使用重复规则，避免不规则周次被系统日历误扩展。
    private static func recurrenceInterval(for weeks: [Int]) -> Int? {
        guard weeks.count > 1 else { return nil }
        let deltas = zip(weeks.dropFirst(), weeks).map { $0 - $1 }
        if deltas.allSatisfy({ $0 == 1 }) { return 1 }
        if deltas.allSatisfy({ $0 == 2 }) { return 2 }
        return nil
    }

    private static func makeEvent(
        key: CourseExportKey,
        weekText: String?,
        week: Int,
        semesterStart: Date,
        exportID: String,
        calendar: EKCalendar,
        eventStore: EKEventStore,
        alarmOffsetsMinutes: Set<Int>
    ) -> EKEvent {
        let event = EKEvent(eventStore: eventStore)
        event.title = key.courseName
        event.location = key.location
        event.notes = CalendarExportSupport.notes(lines: [
            key.teacher.isEmpty ? nil : "教师：\(key.teacher)",
            weekText.map { "周次：\($0)" }
        ], exportID: exportID)
        event.url = CalendarExportSupport.exportURL(for: exportID)
        (event.startDate, event.endDate) = computeTime(for: key, week: week, semesterStart: semesterStart)
        event.calendar = calendar
        for minutes in alarmOffsetsMinutes.sorted() where minutes > 0 {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
        return event
    }

    private static func exportID(
        for courses: [CourseSchedule],
        key: CourseExportKey,
        weeks: [Int],
        semesterStart: Date
    ) -> String {
        let calendarId = courses.first?.calendarId ?? 0
        return CalendarExportSupport.stableID(
            kind: "course",
            components: [
                "\(calendarId)",
                semesterDateString(semesterStart),
                key.courseName,
                key.teacher,
                key.location,
                "\(key.dayOfWeek)",
                "\(key.startPeriod)",
                "\(key.endPeriod)",
                weeks.map(String.init).joined(separator: ",")
            ]
        )
    }

    private static func searchRange(for expectedRanges: [(Date, Date)]) -> DateInterval {
        let starts = expectedRanges.map(\.0)
        let ends = expectedRanges.map(\.1)
        let start = (starts.min() ?? Date()).addingTimeInterval(-86_400)
        let end = (ends.max() ?? start).addingTimeInterval(86_400)
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(86_400)))
    }

    private static func legacyEvent(
        _ event: EKEvent,
        matches key: CourseExportKey,
        expectedRanges: [(Date, Date)]
    ) -> Bool {
        guard CalendarExportSupport.text(event.title, equals: key.courseName),
              CalendarExportSupport.text(event.location, equals: key.location),
              CalendarExportSupport.matchesTime(event, expectedRanges: expectedRanges) else {
            return false
        }

        let notes = event.notes ?? ""
        let teacherMatches = !key.teacher.isEmpty && notes.contains("教师：\(key.teacher)")
        let hasOldWeekLine = notes.contains("周次：")
        return teacherMatches || hasOldWeekLine
    }

    private static func semesterDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func computeTime(for key: CourseExportKey, week: Int, semesterStart: Date) -> (Date, Date) {
        let calendar = Calendar(identifier: .gregorian)
        let timezone = TimeZone(identifier: "Asia/Shanghai")
        let dayOffset = (week - 1) * 7 + (key.dayOfWeek - 1)
        let courseDate = calendar.date(byAdding: .day, value: dayOffset, to: semesterStart) ?? semesterStart
        let startSlot = slot(for: key.startPeriod)
        let endSlot = slot(for: key.endPeriod)

        var startComponents = calendar.dateComponents([.year, .month, .day], from: courseDate)
        let startParts = timeParts(startSlot.start)
        startComponents.hour = startParts.hour
        startComponents.minute = startParts.minute
        startComponents.timeZone = timezone

        var endComponents = calendar.dateComponents([.year, .month, .day], from: courseDate)
        let endParts = timeParts(endSlot.end)
        endComponents.hour = endParts.hour
        endComponents.minute = endParts.minute
        endComponents.timeZone = timezone

        return (
            calendar.date(from: startComponents) ?? courseDate,
            calendar.date(from: endComponents) ?? courseDate
        )
    }

    private static func slot(for period: Int) -> TongjiTimeSlot {
        TongjiTimeSlot.list.first { $0.id == period } ?? TongjiTimeSlot.list.last!
    }

    private static func timeParts(_ text: String) -> (hour: Int, minute: Int) {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }
}
