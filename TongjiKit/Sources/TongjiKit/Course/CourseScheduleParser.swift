import Foundation

/// 移植自 wish_drom `TongjiScheduleProvider.ParseSchedulesFromRawData`。
///
/// 输入：一系统 `findStudentTimetab` 返回的原始 JSON。
/// 输出：按"周-天-节次"展开后的 `CourseSchedule` 列表（已去重）。
public enum CourseScheduleParser {

    public static func parse(
        rawJSON: String,
        calendarId: Int = 0,
        calendarName: String? = nil,
        now: Date = Date()
    ) throws -> [CourseSchedule] {
        guard let data = rawJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = root["data"] as? [[String: Any]] else {
            return []
        }

        var result: [CourseSchedule] = []
        var dedup = Set<String>()

        for item in array {
            guard let courseName = string(item, "courseName"), !courseName.isEmpty else { continue }
            let semester = calendarName ?? string(item, "xnxqmc") ?? currentSemester(for: now)
            let itemTeacher = normalizeTeacher(string(item, "teacherName"))
            let itemLocation = firstNonEmpty([
                string(item, "classRoomI18n"),
                string(item, "roomLable"),
                string(item, "classRoomName"),
                string(item, "classRoom")
            ]) ?? ""

            guard let timeTableList = item["timeTableList"] as? [[String: Any]] else { continue }

            for timeEntry in timeTableList {
                let dayOfWeek = clamp(int(timeEntry, "dayOfWeek") ?? 1, lower: 1, upper: 7)
                let startPeriod = clamp(int(timeEntry, "timeStart") ?? 1, lower: 1, upper: 14)
                var endPeriod = clamp(int(timeEntry, "timeEnd") ?? startPeriod, lower: 1, upper: 14)
                if endPeriod < startPeriod { endPeriod = startPeriod }

                let teacher = normalizeTeacher(string(timeEntry, "teacherName")) ?? itemTeacher ?? ""
                let location = firstNonEmpty([
                    string(timeEntry, "roomIdI18n"),
                    string(timeEntry, "roomLable"),
                    string(item, "classRoomI18n"),
                    string(item, "roomLable"),
                    itemLocation
                ]) ?? ""

                let weekNumText = string(timeEntry, "weekNum")
                var weeks = extractWeeks(timeEntry: timeEntry, weekNumText: weekNumText)
                if weeks.isEmpty {
                    weeks = Array(1...16)
                }

                for week in weeks {
                    let course = CourseSchedule(
                        courseName: courseName,
                        location: location,
                        teacher: teacher,
                        dayOfWeek: dayOfWeek,
                        startPeriod: startPeriod,
                        endPeriod: endPeriod,
                        weekNumber: week,
                        weekText: weekNumText,
                        calendarId: calendarId,
                        calendarName: calendarName ?? semester,
                        semester: semester,
                        syncTime: now
                    )
                    let key = "\(course.calendarId)|\(course.courseName)|\(course.dayOfWeek)|\(course.startPeriod)|\(course.endPeriod)|\(course.weekNumber)|\(course.location)|\(course.teacher)|\(course.semester)"
                    if dedup.insert(key).inserted {
                        result.append(course)
                    }
                }
            }
        }
        return result
    }

    // MARK: - 周次解析

    private static func extractWeeks(timeEntry: [String: Any], weekNumText: String?) -> [Int] {
        if let arr = timeEntry["weeks"] as? [Any] {
            var weeks: Set<Int> = []
            for item in arr {
                if let n = item as? Int, n >= 1 { weeks.insert(n) }
                else if let n = (item as? NSNumber)?.intValue, n >= 1 { weeks.insert(n) }
            }
            if !weeks.isEmpty { return weeks.sorted() }
        }
        if let text = weekNumText, !text.isEmpty {
            return parseWeekNum(text)
        }
        return []
    }

    /// 解析 `"1-16"` / `"1-15单"` / `"2-16双"` / `"1,3,5"` 等格式。
    static func parseWeekNum(_ text: String) -> [Int] {
        var result = Set<Int>()
        var normalized = text.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("[") { normalized.removeFirst() }
        if normalized.hasSuffix("]") { normalized.removeLast() }

        for rawPart in normalized.split(separator: ",") {
            var part = String(rawPart).trimmingCharacters(in: .whitespaces)
            let isOddOnly = part.hasSuffix("单")
            let isEvenOnly = part.hasSuffix("双")
            part = part.replacingOccurrences(of: "单", with: "")
                .replacingOccurrences(of: "双", with: "")
                .trimmingCharacters(in: .whitespaces)

            if part.contains("-") {
                let bounds = part.split(separator: "-").map { String($0).trimmingCharacters(in: .whitespaces) }
                if bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]) {
                    for week in start...end where week >= 1 {
                        if isOddOnly && week % 2 == 0 { continue }
                        if isEvenOnly && week % 2 != 0 { continue }
                        result.insert(week)
                    }
                }
            } else if let week = Int(part), week >= 1 {
                if (!isOddOnly || week % 2 == 1) && (!isEvenOnly || week % 2 == 0) {
                    result.insert(week)
                }
            }
        }
        return result.sorted()
    }

    // MARK: - 字段工具

    private static func string(_ dict: [String: Any], _ key: String) -> String? {
        guard let v = dict[key] else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let n = dict[key] as? Int { return n }
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String { return Int(s) }
        return nil
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for v in values {
            if let v, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                return v.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func clamp(_ v: Int, lower: Int, upper: Int) -> Int {
        return max(lower, min(upper, v))
    }

    /// 多老师姓名归一化：去括号备注、去重、用半角逗号分隔。
    static func normalizeTeacher(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let unified = raw.replacingOccurrences(of: "，", with: ",")
        let parts = unified.split(separator: ",").compactMap { piece -> String? in
            var s = String(piece).trimmingCharacters(in: .whitespaces)
            // 移除 (...) 括号备注
            while let openRange = s.range(of: "("),
                  let closeRange = s.range(of: ")"),
                  openRange.lowerBound < closeRange.upperBound {
                s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                s = s.trimmingCharacters(in: .whitespaces)
            }
            return s.isEmpty ? nil : s
        }
        let uniq = Array(NSOrderedSet(array: parts)) as? [String] ?? parts
        return uniq.isEmpty ? nil : uniq.joined(separator: ",")
    }

    /// 复刻 wish_drom `GetCurrentSemester`：根据当前日期生成 "yyyy-yyyy第N学期"。
    private static func currentSemester(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        if month >= 9 {
            return "\(year)-\(year + 1)第一学期"
        }
        return "\(year - 1)-\(year)第二学期"
    }
}
