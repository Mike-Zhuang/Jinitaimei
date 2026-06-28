import Foundation
import SwiftData

/// 一节课程在课表中的最小单元。
///
/// 每条记录对应"一门课在某一周某天某节次的占用"。同一门课的多周占用
/// 会展开为多条记录，便于按周渲染。设计对齐 wish_drom `CourseSchedule`。
@Model
public final class CourseSchedule {
    public var courseName: String = ""
    public var location: String = ""
    public var teacher: String = ""
    /// 周几，1=周一 ... 7=周日。
    public var dayOfWeek: Int = 1
    /// 起始节次（1-14）。
    public var startPeriod: Int = 1
    public var endPeriod: Int = 1
    /// 该记录所属周次（展开后为单个周）。
    public var weekNumber: Int = 1
    /// 原始 `weekNum` 文本（用于显示，如 `"1-16单"`）。
    public var weekText: String?
    /// 一系统校历 ID。旧缓存默认 0，加载时会归入当前学期。
    public var calendarId: Int = 0
    public var calendarName: String = ""
    public var semester: String = ""
    public var syncTime: Date = Date()

    public init(
        courseName: String,
        location: String,
        teacher: String,
        dayOfWeek: Int,
        startPeriod: Int,
        endPeriod: Int,
        weekNumber: Int,
        weekText: String?,
        calendarId: Int = 0,
        calendarName: String = "",
        semester: String,
        syncTime: Date
    ) {
        self.courseName = courseName
        self.location = location
        self.teacher = teacher
        self.dayOfWeek = dayOfWeek
        self.startPeriod = startPeriod
        self.endPeriod = endPeriod
        self.weekNumber = weekNumber
        self.weekText = weekText
        self.calendarId = calendarId
        self.calendarName = calendarName
        self.semester = semester
        self.syncTime = syncTime
    }
}
