import EventKit
import Foundation

public enum ExamCalendarExporter {
    public static func export(
        exams: [ExamScheduleItem],
        selectedExamIds: Set<Int>,
        to calendar: EKCalendar,
        eventStore: EKEventStore,
        alarmOffsetsMinutes: Set<Int> = []
    ) throws {
        for exam in exams where selectedExamIds.contains(exam.sourceId) {
            guard let startDate = exam.startDate, let endDate = exam.endDate else { continue }
            let exportID = exportID(for: exam, startDate: startDate, endDate: endDate)
            try CalendarExportSupport.removeExistingEvents(
                eventStore: eventStore,
                calendar: calendar,
                range: searchRange(startDate: startDate, endDate: endDate),
                exportID: exportID
            ) { event in
                legacyEvent(event, matches: exam, startDate: startDate, endDate: endDate)
            }

            let event = EKEvent(eventStore: eventStore)
            event.title = "考试：\(exam.courseName)"
            event.location = exam.examSite
            event.startDate = startDate
            event.endDate = endDate
            event.calendar = calendar
            event.notes = CalendarExportSupport.notes(lines: [
                exam.newCourseCode.isEmpty ? nil : "课程代码：\(exam.newCourseCode)",
                exam.newTeachingClassCode.isEmpty ? nil : "教学班：\(exam.newTeachingClassCode)",
                exam.calendarName.isEmpty ? nil : "学期：\(exam.calendarName)",
                exam.examTimeText.isEmpty ? nil : "原始时间：\(exam.examTimeText)",
                exam.remark.isEmpty ? nil : "备注：\(exam.remark)"
            ], exportID: exportID)
            event.url = CalendarExportSupport.exportURL(for: exportID)
            for minutes in alarmOffsetsMinutes.sorted() where minutes > 0 {
                event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
            }
            try eventStore.save(event, span: .thisEvent, commit: false)
        }
        try eventStore.commit()
    }

    private static func exportID(for exam: ExamScheduleItem, startDate: Date, endDate: Date) -> String {
        CalendarExportSupport.stableID(
            kind: "exam",
            components: [
                "\(exam.calendarId)",
                "\(exam.sourceId)",
                exam.courseName,
                exam.newCourseCode,
                exam.newTeachingClassCode,
                exam.examSite,
                timestampString(startDate),
                timestampString(endDate)
            ]
        )
    }

    private static func searchRange(startDate: Date, endDate: Date) -> DateInterval {
        let start = startDate.addingTimeInterval(-86_400)
        let end = endDate.addingTimeInterval(86_400)
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(86_400)))
    }

    private static func legacyEvent(
        _ event: EKEvent,
        matches exam: ExamScheduleItem,
        startDate: Date,
        endDate: Date
    ) -> Bool {
        guard CalendarExportSupport.text(event.title, equals: "考试：\(exam.courseName)"),
              CalendarExportSupport.text(event.location, equals: exam.examSite),
              CalendarExportSupport.matchesTime(event, expectedRanges: [(startDate, endDate)]) else {
            return false
        }

        let notes = event.notes ?? ""
        let codeMatches = !exam.newCourseCode.isEmpty && notes.contains("课程代码：\(exam.newCourseCode)")
        let classMatches = !exam.newTeachingClassCode.isEmpty && notes.contains("教学班：\(exam.newTeachingClassCode)")
        let timeMatches = !exam.examTimeText.isEmpty && notes.contains("原始时间：\(exam.examTimeText)")
        return codeMatches || classMatches || timeMatches
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }
}
