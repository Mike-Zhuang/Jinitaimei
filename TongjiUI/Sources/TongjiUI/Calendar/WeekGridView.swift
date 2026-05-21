import SwiftUI
import TongjiKit

/// 周课表网格：7 列（周一~周日）× 14 节。
///
/// 采用绝对定位渲染：每门课只画一个 cell，高度 = (endPeriod - startPeriod + 1) × rowHeight，
/// 跨节课（如 1-2 节、3-4 节）会自然合并成一整块，不再出现"被横线分成两半"的视觉。
///
/// 顶部表头展示本周每一天的真实日期（学期起始日 + 周偏移 + 日偏移）。
struct WeekGridView: View {

    let courses: [CourseSchedule]
    /// 本周周一对应的真实日期，nil 时表头只显示"周一/周二/…"
    let weekStartDate: Date?

    private let periodCount = 14
    private let dayCount = 7
    private let timeColumnWidth: CGFloat = 32
    private let rowHeight: CGFloat = 56
    private let cellSpacing: CGFloat = 4

    @State private var detailCourse: CourseSchedule?

    var body: some View {
        ScrollView {
            VStack(spacing: cellSpacing) {
                GeometryReader { geo in
                    let totalWidth = geo.size.width
                    let availableWidth = totalWidth - timeColumnWidth - cellSpacing
                    let cellWidth = max(
                        20,
                        (availableWidth - CGFloat(dayCount - 1) * cellSpacing) / CGFloat(dayCount)
                    )

                    headerRow(cellWidth: cellWidth)
                }
                .frame(height: 44)

                GeometryReader { geo in
                    let totalWidth = geo.size.width
                    let availableWidth = totalWidth - timeColumnWidth - cellSpacing
                    let cellWidth = max(
                        20,
                        (availableWidth - CGFloat(dayCount - 1) * cellSpacing) / CGFloat(dayCount)
                    )

                    ZStack(alignment: .topLeading) {
                        // 节次序号列
                        VStack(spacing: cellSpacing) {
                            ForEach(1...periodCount, id: \.self) { period in
                                Text("\(period)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(width: timeColumnWidth, height: rowHeight)
                            }
                        }

                        // 日期分隔背景（每一天一列浅灰底）
                        ForEach(1...dayCount, id: \.self) { day in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.tertiarySystemBackground))
                                .frame(
                                    width: cellWidth,
                                    height: gridHeight
                                )
                                .offset(
                                    x: dayOffsetX(day: day, cellWidth: cellWidth),
                                    y: 0
                                )
                        }

                        // 课程块（按起止节次跨多行渲染）
                        ForEach(uniqueCourses, id: \.persistentModelID) { course in
                            let span = max(1, course.endPeriod - course.startPeriod + 1)
                            let blockHeight = rowHeight * CGFloat(span) + cellSpacing * CGFloat(span - 1)

                            courseCell(course: course)
                                .frame(width: cellWidth, height: blockHeight)
                                .offset(
                                    x: dayOffsetX(day: course.dayOfWeek, cellWidth: cellWidth),
                                    y: CGFloat(course.startPeriod - 1) * (rowHeight + cellSpacing)
                                )
                        }
                    }
                    .frame(height: gridHeight, alignment: .topLeading)
                }
                .frame(height: gridHeight)
            }
            .padding(8)
        }
        .sheet(item: $detailCourse) { course in
            CourseDetailSheet(course: course)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Header

    private func headerRow(cellWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: cellSpacing) {
            Spacer().frame(width: timeColumnWidth)
            ForEach(1...dayCount, id: \.self) { day in
                VStack(spacing: 2) {
                    Text(weekdayLabel(day))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let dateText = dateLabel(for: day) {
                        Text(dateText)
                            .font(.system(size: 11, weight: isToday(day: day) ? .bold : .regular))
                            .foregroundColor(isToday(day: day) ? .accentColor : .primary)
                    }
                }
                .frame(width: cellWidth)
            }
        }
    }

    private func weekdayLabel(_ day: Int) -> String {
        ["一", "二", "三", "四", "五", "六", "日"][max(0, min(6, day - 1))]
    }

    private func dateLabel(for day: Int) -> String? {
        guard let weekStartDate else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(byAdding: .day, value: day - 1, to: weekStartDate) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func isToday(day: Int) -> Bool {
        guard let weekStartDate else { return false }
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(byAdding: .day, value: day - 1, to: weekStartDate) else {
            return false
        }
        return calendar.isDateInToday(date)
    }

    // MARK: - Course Cell

    private func courseCell(course: CourseSchedule) -> some View {
        Button {
            detailCourse = course
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.courseName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !course.location.isEmpty {
                    Text(course.location)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colorFor(course: course))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// 按课程名 hash 选稳定颜色。
    private func colorFor(course: CourseSchedule) -> Color {
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .brown, .cyan
        ]
        let hash = abs(course.courseName.hashValue)
        return palette[hash % palette.count]
    }

    // MARK: - Layout helpers

    /// 同一周 + 同一天 + 同一门课 + 同一时段可能在 SwiftData 里有 N 条（每周一条），
    /// 周视图按周筛选过后，对同 (course, day, start, end) 仅保留一条，避免重叠渲染。
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

    private var gridHeight: CGFloat {
        CGFloat(periodCount) * rowHeight + CGFloat(periodCount - 1) * cellSpacing
    }

    private func dayOffsetX(day: Int, cellWidth: CGFloat) -> CGFloat {
        timeColumnWidth + cellSpacing + CGFloat(day - 1) * (cellWidth + cellSpacing)
    }
}

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
