import SwiftUI
import TongjiKit

/// 周课表网格：7 列（周一~周日）× 12 节。
///
/// 视觉参考 DanXi-swift `FudanUI/Utils/CalendarFramework.swift`：
/// - 左侧时间列：节次编号 + 起止时间（小字 secondary）
/// - 顶部日期表头：日期 (M/d) + 周几缩写
/// - 课程块：浅色填充（accent 0.2）+ 主色文字 + 左侧 3pt 色条
/// - 课程跨节自然合并为一整块
struct WeekGridView: View {

    let courses: [CourseSchedule]
    /// 本周周一对应的真实日期，nil 时表头隐藏日期行
    let weekStartDate: Date?

    private let periodCount = TongjiTimeSlot.list.count
    private let dayCount = 7

    @ScaledMetric private var sidebarWidth: CGFloat = 44
    @ScaledMetric private var headerHeight: CGFloat = 44
    @ScaledMetric private var rowHeight: CGFloat = 54

    @State private var detailCourse: CourseSchedule?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                TimeslotsSidebar(
                    headerHeight: headerHeight,
                    rowHeight: rowHeight,
                    width: sidebarWidth
                )

                GeometryReader { geo in
                    let dx = max(20, geo.size.width / CGFloat(dayCount))
                    VStack(alignment: .leading, spacing: 0) {
                        DateHeader(
                            weekStartDate: weekStartDate,
                            dx: dx,
                            height: headerHeight
                        )
                        CalendarEvents(
                            courses: uniqueCourses,
                            dx: dx,
                            dy: rowHeight,
                            periodCount: periodCount,
                            onTap: { detailCourse = $0 }
                        )
                    }
                }
                .frame(height: headerHeight + CGFloat(periodCount) * rowHeight)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .sheet(item: $detailCourse) { course in
            CourseDetailSheet(course: course)
                .presentationDetents([.medium, .large])
        }
    }

    /// 同一周 + 同一天 + 同一门课 + 同一时段在 SwiftData 里可能存了多周一份，
    /// 视图层做一次去重避免重叠绘制。
    private var uniqueCourses: [CourseSchedule] {
        var seen = Set<String>()
        var result: [CourseSchedule] = []
        for course in courses {
            let key = "\(course.courseName)|\(course.dayOfWeek)|\(course.startPeriod)|\(course.endPeriod)|\(course.location)"
            if seen.insert(key).inserted {
                result.append(course)
            }
        }
        return result
    }
}

// MARK: - 左侧时间列

private struct TimeslotsSidebar: View {
    let headerHeight: CGFloat
    let rowHeight: CGFloat
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: width, height: headerHeight)
            ForEach(TongjiTimeSlot.list) { slot in
                VStack(spacing: 2) {
                    Text(String(slot.id))
                        .font(.system(size: 13, weight: .semibold))
                    Text(slot.start)
                        .font(.system(size: 9))
                    Text(slot.end)
                        .font(.system(size: 9))
                }
                .foregroundColor(.secondary)
                .frame(width: width, height: rowHeight)
            }
        }
    }
}

// MARK: - 顶部日期表头

private struct DateHeader: View {
    let weekStartDate: Date?
    let dx: CGFloat
    let height: CGFloat
    private let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                cell(for: i)
                    .frame(width: dx, height: height)
            }
        }
    }

    @ViewBuilder
    private func cell(for i: Int) -> some View {
        let date = weekStartDate.flatMap {
            calendar.date(byAdding: .day, value: i, to: $0)
        }
        let isToday = date.map { calendar.isDateInToday($0) } ?? false

        VStack(spacing: 4) {
            if let date {
                Text(dateString(for: date))
                    .font(.system(size: 15))
                    .foregroundColor(isToday ? .accentColor : .primary)
            }
            Text(weekdayString(for: i))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .fontWeight(isToday ? .bold : .regular)
    }

    private func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func weekdayString(for i: Int) -> String {
        ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][i]
    }
}

// MARK: - 课程块容器

private struct CalendarEvents: View {
    let courses: [CourseSchedule]
    let dx: CGFloat
    let dy: CGFloat
    let periodCount: Int
    let onTap: (CourseSchedule) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            GridBackground(width: 7, height: periodCount, dx: dx, dy: dy)

            ForEach(courses, id: \.persistentModelID) { course in
                let span = max(1, course.endPeriod - course.startPeriod + 1)
                CourseCell(course: course, span: span, dx: dx, dy: dy) {
                    onTap(course)
                }
                .offset(
                    x: CGFloat(course.dayOfWeek - 1) * dx,
                    y: CGFloat(course.startPeriod - 1) * dy
                )
            }
        }
        .frame(width: CGFloat(7) * dx, height: CGFloat(periodCount) * dy, alignment: .topLeading)
    }
}

// MARK: - 单个课程块

private struct CourseCell: View {
    let course: CourseSchedule
    let span: Int
    let dx: CGFloat
    let dy: CGFloat
    let onTap: () -> Void

    @ScaledMetric private var titleSize: CGFloat = 13
    @ScaledMetric private var subtitleSize: CGFloat = 9

    private var color: Color { CalendarPalette.color(for: course.courseName) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.courseName)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(color)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 4)

                    if !course.location.isEmpty {
                        Text(course.location)
                            .font(.system(size: subtitleSize))
                            .foregroundColor(color.opacity(0.85))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
                .padding(.trailing, 4)
                Spacer(minLength: 0)
            }
            .frame(width: dx, height: CGFloat(span) * dy, alignment: .topLeading)
            .background(color.opacity(0.18))
            .overlay(
                Rectangle()
                    .frame(width: 3)
                    .foregroundColor(color),
                alignment: .leading
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 网格背景

private struct GridBackground: View {
    let width: Int
    let height: Int
    let dx: CGFloat
    let dy: CGFloat

    var body: some View {
        Canvas { context, _ in
            let color = Color.secondary.opacity(0.18)

            for i in 0...height {
                let y = CGFloat(i) * dy
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: CGFloat(width) * dx, y: y))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
            for i in 0...width {
                let x = CGFloat(i) * dx
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: CGFloat(height) * dy))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
        }
        .frame(width: CGFloat(width) * dx, height: CGFloat(height) * dy)
    }
}

// MARK: - 颜色

enum CalendarPalette {
    private static let palette: [Color] = [
        .red, .pink, .purple, .blue, .cyan, .teal, .green, .orange, .brown, .indigo
    ]

    /// 按课程名稳定哈希挑选 palette 中的颜色（DanXi 的 `randomColor` 思路）。
    static func color(for name: String) -> Color {
        var sum = 0
        for c in name.utf16 { sum &+= Int(c) }
        return palette[abs(sum) % palette.count]
    }
}

// MARK: - 详情弹窗

struct CourseDetailSheet: View {
    let course: CourseSchedule

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("课程", value: course.courseName)
                LabeledContent("教师", value: course.teacher.isEmpty ? "—" : course.teacher)
                LabeledContent("地点", value: course.location.isEmpty ? "—" : course.location)
                LabeledContent("时间", value: "周\(weekdayChinese(course.dayOfWeek)) 第\(course.startPeriod)-\(course.endPeriod)节")
                LabeledContent("周次", value: course.weekText ?? "第\(course.weekNumber)周")
                LabeledContent("学期", value: course.semester)
            }
            .navigationTitle(course.courseName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func weekdayChinese(_ day: Int) -> String {
        ["一", "二", "三", "四", "五", "六", "日"][max(0, min(6, day - 1))]
    }
}
