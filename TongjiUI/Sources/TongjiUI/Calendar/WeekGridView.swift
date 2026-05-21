import SwiftUI
import TongjiKit

/// 周课表网格：7 列（周一~周日）× 14 节。
///
/// 设计上为最小可用版本：同一格只展示首门课的卡片，多门冲突时点击展开。
/// 进阶视觉（节次时段、跨节合并）后续迭代再加。
struct WeekGridView: View {

    let courses: [CourseSchedule]
    @State private var detailCourse: CourseSchedule?

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                headerRow
                ForEach(1...14, id: \.self) { period in
                    rowFor(period: period)
                }
            }
            .padding(8)
        }
        .sheet(item: $detailCourse) { course in
            CourseDetailSheet(course: course)
                .presentationDetents([.medium, .large])
        }
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            cell(width: 32) { Text("节").font(.caption2).foregroundColor(.secondary) }
            ForEach(1...7, id: \.self) { day in
                cell(flexible: true) {
                    Text(weekdayLabel(day))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func rowFor(period: Int) -> some View {
        HStack(spacing: 4) {
            cell(width: 32) {
                Text("\(period)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            ForEach(1...7, id: \.self) { day in
                cell(flexible: true) {
                    if let course = courseAt(day: day, period: period) {
                        Button {
                            detailCourse = course
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(course.courseName)
                                    .font(.caption2)
                                    .lineLimit(2)
                                if !course.location.isEmpty {
                                    Text(course.location)
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.85))
                                        .lineLimit(1)
                                }
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(colorFor(course: course))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(height: 56)
    }

    @ViewBuilder
    private func cell<Content: View>(width: CGFloat? = nil, flexible: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        if flexible {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let width {
            content()
                .frame(width: width)
        } else {
            content()
        }
    }

    private func courseAt(day: Int, period: Int) -> CourseSchedule? {
        courses.first {
            $0.dayOfWeek == day &&
            period >= $0.startPeriod &&
            period <= $0.endPeriod
        }
    }

    private func weekdayLabel(_ day: Int) -> String {
        ["一", "二", "三", "四", "五", "六", "日"][day - 1]
    }

    /// 按课程名 hash 出稳定的颜色，避免相邻同色。
    private func colorFor(course: CourseSchedule) -> Color {
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .brown, .cyan
        ]
        let hash = abs(course.courseName.hashValue)
        return palette[hash % palette.count]
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

