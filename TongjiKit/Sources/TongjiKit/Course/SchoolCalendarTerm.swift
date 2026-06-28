import Foundation
import SwiftData

/// 一系统校历学期元数据。
///
/// 课表、考试与导出都以 `calendarId` 作为学期边界，避免不同学期的数据互相覆盖。
@Model
public final class SchoolCalendarTerm {
    @Attribute(.unique) public var calendarId: Int = 0
    public var fullName: String = ""
    public var beginDay: Date?
    public var endDay: Date?
    public var weekNum: Int = 0
    public var currentTermFlag: Bool = false
    public var nextTermFlag: Bool = false
    public var syncTime: Date = Date()

    public init(
        calendarId: Int,
        fullName: String,
        beginDay: Date?,
        endDay: Date?,
        weekNum: Int,
        currentTermFlag: Bool,
        nextTermFlag: Bool,
        syncTime: Date = Date()
    ) {
        self.calendarId = calendarId
        self.fullName = fullName
        self.beginDay = beginDay
        self.endDay = endDay
        self.weekNum = weekNum
        self.currentTermFlag = currentTermFlag
        self.nextTermFlag = nextTermFlag
        self.syncTime = syncTime
    }
}

public struct SchoolCalendarTermInfo: Sendable, Hashable {
    public let calendarId: Int
    public let fullName: String
    public let beginDay: Date?
    public let endDay: Date?
    public let weekNum: Int
    public let currentTermFlag: Bool
    public let nextTermFlag: Bool

    public init(
        calendarId: Int,
        fullName: String,
        beginDay: Date?,
        endDay: Date?,
        weekNum: Int,
        currentTermFlag: Bool,
        nextTermFlag: Bool
    ) {
        self.calendarId = calendarId
        self.fullName = fullName
        self.beginDay = beginDay
        self.endDay = endDay
        self.weekNum = weekNum
        self.currentTermFlag = currentTermFlag
        self.nextTermFlag = nextTermFlag
    }
}
