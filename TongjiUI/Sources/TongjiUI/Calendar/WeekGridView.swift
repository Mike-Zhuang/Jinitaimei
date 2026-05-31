import SwiftUI
import TongjiKit

/// 周课表网格：7 列（周一~周日）× 11 节。
///
/// 排版规则（对齐 DanXi-swift `FudanUI/Pages/CoursePage.swift` 的 `ViewThatFits` 思路）：
/// - 单天列宽 `dx` **固定**：每节高度 `dy` 也固定。
/// - 整张网格放进横向 `ScrollView`：在 iPhone 上自然呈现"周一~周五完整 + 周六一小条"
///   的效果（5.x 列宽度），左右滑动可看完周六、周日。
/// - 左侧时间侧栏 **不参与横向滚动**，始终钉在最左侧。
/// - 课程标题不加 `lineLimit`，根据单元格高度自动换行——长名字（如
///   "普通物理(荣)"）会完整显示成两行。
struct WeekGridView: View {

    let courses: [CourseSchedule]
    /// 本周周一对应的真实日期；nil 时表头隐藏日期行
    let weekStartDate: Date?

    private let periodCount = TongjiTimeSlot.list.count
    private let dayCount = 7

    @ScaledMetric private var sidebarWidth: CGFloat = 44
    @ScaledMetric private var headerHeight: CGFloat = 44
    @ScaledMetric private var rowHeight: CGFloat = 60
    /// 单日列宽：固定 68pt，配合 iPhone 主流宽度（≈ 393pt - 8pt padding - 44pt 侧栏 ≈ 333pt
    /// 可视区 ≈ 4.9 列），刚好呈现"周一-周五完整 + 周六一小条"。
    @ScaledMetric private var dayWidth: CGFloat = 68

    @State private var detailCourse: CourseSchedule?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TimeslotsSidebar(
                headerHeight: headerHeight,
                rowHeight: rowHeight,
                width: sidebarWidth
            )

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DateHeader(
                        weekStartDate: weekStartDate,
                        dx: dayWidth,
                        height: headerHeight
                    )
                    CalendarEvents(
                        courses: uniqueCourses,
                        dx: dayWidth,
                        dy: rowHeight,
                        periodCount: periodCount,
                        onTap: { detailCourse = $0 }
                    )
                }
                .frame(width: CGFloat(dayCount) * dayWidth, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .sheet(item: $detailCourse) { course in
            CourseDetailSheet(course: course)
                .presentationDetents([.medium, .large])
        }
    }

    /// 同一周 + 同一天 + 同一门课 + 同一时段在 SwiftData 里可能存了多份，
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
    @ScaledMetric private var subtitleSize: CGFloat = 10

    private var color: Color { CalendarPalette.color(for: course.courseName) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                // 不加 lineLimit，让 SwiftUI 按可用高度自动换行；
                // fixedSize 强制按内容垂直撑开，避免文本被外层 frame 截断为单行
                Text(course.courseName)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundColor(color)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                if !course.location.isEmpty {
                    Text(course.location)
                        .font(.system(size: subtitleSize))
                        .foregroundColor(color.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 3)
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

    /// 按课程名稳定哈希挑选 palette 中的颜色（与 DanXi `randomColor` 同思路）。
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

struct CoursePageExamRow: View {
    let exam: ExamScheduleItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(.indigo)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(exam.courseName)
                    .font(.headline)
                Text("\(exam.displayDate)  \(exam.displayTime)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(exam.displayLocation)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}

struct CoursePageExamDetailSheet: View {
    let exam: ExamScheduleItem

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(exam.courseName)
                            .font(.title3)
                            .bold()
                        if !exam.newCourseCode.isEmpty {
                            Text(exam.newCourseCode)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("考试信息") {
                    LabeledContent("日期", value: exam.displayDate)
                    LabeledContent("时间", value: exam.displayTime)
                    LabeledContent("地点", value: exam.displayLocation)
                    if !exam.newTeachingClassCode.isEmpty {
                        LabeledContent("教学班", value: exam.newTeachingClassCode)
                    }
                }

                if !exam.remark.isEmpty {
                    Section("备注") {
                        Text(exam.remark)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("考试详情")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
