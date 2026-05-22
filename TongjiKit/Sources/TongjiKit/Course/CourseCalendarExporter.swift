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

        if let interval = recurrenceInterval(for: weeks) {
            let event = makeEvent(
                key: key,
                weekText: courses.first?.weekText,
                week: firstWeek,
                semesterStart: semesterStart,
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
        calendar: EKCalendar,
        eventStore: EKEventStore,
        alarmOffsetsMinutes: Set<Int>
    ) -> EKEvent {
        let event = EKEvent(eventStore: eventStore)
        event.title = key.courseName
        event.location = key.location
        event.notes = [
            key.teacher.isEmpty ? nil : "教师：\(key.teacher)",
            weekText.map { "周次：\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        (event.startDate, event.endDate) = computeTime(for: key, week: week, semesterStart: semesterStart)
        event.calendar = calendar
        for minutes in alarmOffsetsMinutes.sorted() where minutes > 0 {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
        return event
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
