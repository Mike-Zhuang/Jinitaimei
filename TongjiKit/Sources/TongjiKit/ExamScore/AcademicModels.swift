import Foundation
import SwiftData

@Model
public final class ExamScheduleItem {
    public var sourceId: Int = 0
    public var calendarId: Int = 0
    public var calendarName: String = ""
    public var switchRemark: String = ""
    public var syncTime: Date = Date()
    public var sortIndex: Int = 0
    public var courseName: String = ""
    public var newCourseCode: String = ""
    public var newTeachingClassCode: String = ""
    public var examDateText: String = ""
    public var startTimeText: String = ""
    public var endTimeText: String = ""
    public var examSite: String = ""
    public var examTimeText: String = ""
    public var remark: String = ""
    public var examSituation: Int = 0
    public var isOpen: Int = 0

    public init(
        sourceId: Int,
        calendarId: Int,
        calendarName: String,
        switchRemark: String,
        syncTime: Date,
        sortIndex: Int,
        courseName: String,
        newCourseCode: String,
        newTeachingClassCode: String,
        examDateText: String,
        startTimeText: String,
        endTimeText: String,
        examSite: String,
        examTimeText: String,
        remark: String,
        examSituation: Int,
        isOpen: Int
    ) {
        self.sourceId = sourceId
        self.calendarId = calendarId
        self.calendarName = calendarName
        self.switchRemark = switchRemark
        self.syncTime = syncTime
        self.sortIndex = sortIndex
        self.courseName = courseName
        self.newCourseCode = newCourseCode
        self.newTeachingClassCode = newTeachingClassCode
        self.examDateText = examDateText
        self.startTimeText = startTimeText
        self.endTimeText = endTimeText
        self.examSite = examSite
        self.examTimeText = examTimeText
        self.remark = remark
        self.examSituation = examSituation
        self.isOpen = isOpen
    }

    public var hasScheduledTime: Bool {
        startDate != nil && endDate != nil
    }

    public var startDate: Date? {
        AcademicDateParser.examDate(dateText: examDateText, timeText: startTimeText)
    }

    public var endDate: Date? {
        AcademicDateParser.examDate(dateText: examDateText, timeText: endTimeText)
    }

    public var displayDate: String {
        guard let startDate else {
            return examTimeText.isEmpty ? "时间未定" : examTimeText
        }
        return Self.dateFormatter.string(from: startDate)
    }

    public var displayTime: String {
        if !startTimeText.isEmpty, !endTimeText.isEmpty {
            return "\(startTimeText)-\(endTimeText)"
        }
        return examTimeText
    }

    public var displayLocation: String {
        examSite.isEmpty ? "地点未定" : examSite
    }

    public var displayRemark: String {
        if !remark.isEmpty { return remark }
        if !examTimeText.isEmpty { return examTimeText }
        return "考察安排未公布"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd EEEE"
        return formatter
    }()
}

@Model
public final class GradeSummarySnapshot {
    public var totalGradePoint: String = ""
    public var actualCredit: String = ""
    public var failingCredits: String = ""
    public var failingCourseCount: String = ""
    public var syncTime: Date = Date()

    public init(
        totalGradePoint: String,
        actualCredit: String,
        failingCredits: String,
        failingCourseCount: String,
        syncTime: Date
    ) {
        self.totalGradePoint = totalGradePoint
        self.actualCredit = actualCredit
        self.failingCredits = failingCredits
        self.failingCourseCount = failingCourseCount
        self.syncTime = syncTime
    }
}

@Model
public final class GradeCourseRecord {
    public var sourceId: Int = 0
    public var termCode: Int = 0
    public var termName: String = ""
    public var calName: String = ""
    public var termAveragePoint: String = ""
    public var sortIndex: Int = 0
    public var courseCode: String = ""
    public var newCourseCode: String = ""
    public var courseName: String = ""
    public var courseCategory: String = ""
    public var creditText: String = ""
    public var gradePointText: String = ""
    public var scoreText: String = ""
    public var scoreExamType: String = ""
    public var publicCourseName: String = ""
    public var isPassName: String = ""
    public var updateTimeText: String = ""
    public var syncTime: Date = Date()

    public init(
        sourceId: Int,
        termCode: Int,
        termName: String,
        calName: String,
        termAveragePoint: String,
        sortIndex: Int,
        courseCode: String,
        newCourseCode: String,
        courseName: String,
        courseCategory: String,
        creditText: String,
        gradePointText: String,
        scoreText: String,
        scoreExamType: String,
        publicCourseName: String,
        isPassName: String,
        updateTimeText: String,
        syncTime: Date
    ) {
        self.sourceId = sourceId
        self.termCode = termCode
        self.termName = termName
        self.calName = calName
        self.termAveragePoint = termAveragePoint
        self.sortIndex = sortIndex
        self.courseCode = courseCode
        self.newCourseCode = newCourseCode
        self.courseName = courseName
        self.courseCategory = courseCategory
        self.creditText = creditText
        self.gradePointText = gradePointText
        self.scoreText = scoreText
        self.scoreExamType = scoreExamType
        self.publicCourseName = publicCourseName
        self.isPassName = isPassName
        self.updateTimeText = updateTimeText
        self.syncTime = syncTime
    }

    public var displayCourseCode: String {
        !newCourseCode.isEmpty ? newCourseCode : courseCode
    }
}

public struct TongjiExamFetchResult: Sendable {
    public let calendarId: Int
    public let calendarName: String
    public let switchRemark: String
    public let items: [TongjiExamItem]
}

public struct TongjiExamItem: Sendable {
    public let sourceId: Int
    public let courseName: String
    public let newCourseCode: String
    public let newTeachingClassCode: String
    public let examDateText: String
    public let startTimeText: String
    public let endTimeText: String
    public let examSite: String
    public let examTimeText: String
    public let remark: String
    public let examSituation: Int
    public let isOpen: Int
}

public struct TongjiGradeFetchResult: Sendable {
    public let summary: TongjiGradeSummary
    public let terms: [TongjiGradeTerm]
}

public struct TongjiGradeSummary: Sendable {
    public let totalGradePoint: String
    public let actualCredit: String
    public let failingCredits: String
    public let failingCourseCount: String
}

public struct TongjiGradeTerm: Sendable {
    public let termCode: Int
    public let termName: String
    public let calName: String
    public let averagePoint: String
    public let courses: [TongjiGradeCourse]
}

public struct TongjiGradeCourse: Sendable {
    public let sourceId: Int
    public let courseCode: String
    public let newCourseCode: String
    public let courseName: String
    public let courseCategory: String
    public let creditText: String
    public let gradePointText: String
    public let scoreText: String
    public let scoreExamType: String
    public let publicCourseName: String
    public let isPassName: String
    public let updateTimeText: String
}

enum AcademicDateParser {
    static func examDate(dateText: String, timeText: String) -> Date? {
        let datePart = dateText.split(separator: " ").first.map(String.init) ?? dateText
        guard !datePart.isEmpty, !timeText.isEmpty else { return nil }
        let combined = "\(datePart) \(timeText)"
        return examDateTimeFormatter.date(from: combined)
    }

    private static let examDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
