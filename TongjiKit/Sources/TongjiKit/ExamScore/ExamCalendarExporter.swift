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
            let event = EKEvent(eventStore: eventStore)
            event.title = "考试：\(exam.courseName)"
            event.location = exam.examSite
            event.startDate = startDate
            event.endDate = endDate
            event.calendar = calendar
            event.notes = [
                exam.newCourseCode.isEmpty ? nil : "课程代码：\(exam.newCourseCode)",
                exam.newTeachingClassCode.isEmpty ? nil : "教学班：\(exam.newTeachingClassCode)",
                exam.calendarName.isEmpty ? nil : "学期：\(exam.calendarName)",
                exam.examTimeText.isEmpty ? nil : "原始时间：\(exam.examTimeText)",
                exam.remark.isEmpty ? nil : "备注：\(exam.remark)"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            for minutes in alarmOffsetsMinutes.sorted() where minutes > 0 {
                event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
            }
            try eventStore.save(event, span: .thisEvent, commit: false)
        }
        try eventStore.commit()
    }
}
