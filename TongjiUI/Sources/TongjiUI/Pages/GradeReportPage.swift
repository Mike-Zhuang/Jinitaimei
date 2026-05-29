import SwiftData
import SwiftUI
import TongjiKit

public struct GradeReportPage: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var store: GradeStore
    @State private var selectedTerm: GradeTermSummary?
    @State private var selectedCourse: GradeCourseRecord?

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: GradeStore(modelContext: modelContext))
    }

    public var body: some View {
        List {
            if !campusModel.loggedIn {
                ContentUnavailableView(
                    "请先登录校园账户",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("登录后可查看课程成绩。")
                )
                .listEmptyRowStyle()
            } else {
                if let summary = store.summary {
                    GradeSummarySection(summary: summary, latestTerm: store.latestTerm)
                } else if store.isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在同步课程成绩")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !store.terms.isEmpty {
                    SemesterPickerSection(terms: store.terms, selectedTerm: selectedTermBinding)
                }

                let visibleCourses = selectedTerm.map { store.courses(in: $0) } ?? []
                if visibleCourses.isEmpty, !store.isLoading {
                    ContentUnavailableView("暂无成绩记录", systemImage: "graduationcap.circle")
                        .listEmptyRowStyle()
                } else if !visibleCourses.isEmpty {
                    Section {
                        ForEach(visibleCourses) { course in
                            Button {
                                selectedCourse = course
                            } label: {
                                GradeCourseRow(course: course)
                            }
                            .tint(.primary)
                        }
                    } footer: {
                        if let selectedTerm {
                            Text("本学期平均绩点：\(selectedTerm.averagePoint.isEmpty ? "暂无" : selectedTerm.averagePoint)")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("课程成绩")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            guard campusModel.loggedIn else { return }
            await syncAndSelectLatestTerm()
        }
        .task {
            guard campusModel.loggedIn else { return }
            if store.summary == nil, store.courses.isEmpty {
                await syncAndSelectLatestTerm()
            } else {
                selectLatestTermIfNeeded()
            }
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            if !loggedIn {
                store.clearLocalData()
                selectedTerm = nil
            }
        }
        .onChange(of: store.terms) { _, _ in
            selectLatestTermIfNeeded()
        }
        .sheet(item: $selectedCourse) { course in
            GradeDetailSheet(course: course)
                .presentationDetents([.medium, .large])
        }
        .alert("加载失败", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("好") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var selectedTermBinding: Binding<GradeTermSummary> {
        Binding {
            selectedTerm ?? store.latestTerm ?? store.terms.first!
        } set: { term in
            selectedTerm = term
        }
    }

    private func syncAndSelectLatestTerm() async {
        await store.sync()
        selectLatestTermIfNeeded()
    }

    private func selectLatestTermIfNeeded() {
        guard !store.terms.isEmpty else { return }
        if let selectedTerm, store.terms.contains(selectedTerm) {
            return
        }
        selectedTerm = store.latestTerm
    }
}

private struct GradeSummarySection: View {
    let summary: GradeSummarySnapshot
    let latestTerm: GradeTermSummary?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(clean(summary.totalGradePoint))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("总平均绩点")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let latestTerm {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(latestTerm.averagePoint.isEmpty ? "暂无" : latestTerm.averagePoint)
                                .font(.title2)
                                .bold()
                            Text("最近学期")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 12) {
                    summaryMetric("实修学分", clean(summary.actualCredit))
                    summaryMetric("不及格学分", clean(summary.failingCredits))
                    summaryMetric("不及格门数", summary.failingCourseCount.isEmpty ? "0" : summary.failingCourseCount)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func summaryMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clean(_ value: String) -> String {
        guard let number = Double(value) else { return value.isEmpty ? "暂无" : value }
        if number.rounded() == number {
            return String(Int(number))
        }
        return String(format: "%.2f", number)
    }
}

private struct SemesterPickerSection: View {
    let terms: [GradeTermSummary]
    @Binding var selectedTerm: GradeTermSummary

    var body: some View {
        Section {
            HStack {
                Button {
                    move(offset: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(selectedTerm == terms.first)

                Spacer()

                Menu(selectedTerm.termName) {
                    ForEach(terms) { term in
                        Button(term.termName) {
                            selectedTerm = term
                        }
                    }
                }
                .foregroundStyle(.primary)

                Spacer()

                Button {
                    move(offset: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(selectedTerm == terms.last)
            }
            .listRowBackground(Color.clear)
        }
    }

    private func move(offset: Int) {
        guard let index = terms.firstIndex(of: selectedTerm) else { return }
        let nextIndex = index + offset
        guard terms.indices.contains(nextIndex) else { return }
        selectedTerm = terms[nextIndex]
    }
}

private struct GradeCourseRow: View {
    let course: GradeCourseRecord

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !course.courseCategory.isEmpty {
                    Text(course.courseCategory)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(course.courseName)
                    .font(.headline)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(course.scoreText.isEmpty ? "暂无" : course.scoreText)
                    .font(.title3.monospaced())
                    .fontWeight(.bold)
                if !course.gradePointText.isEmpty {
                    Text("绩点 \(course.gradePointText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GradeDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let course: GradeCourseRecord

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            if !course.displayCourseCode.isEmpty {
                                Text(course.displayCourseCode)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text(course.courseName)
                                .font(.title3)
                                .bold()
                        }
                        Spacer()
                        Text(course.scoreText.isEmpty ? "暂无" : course.scoreText)
                            .font(.title3.monospaced())
                            .bold()
                    }
                }

                Section("成绩信息") {
                    LabeledContent("学期", value: course.termName)
                    LabeledContent("学分", value: course.creditText.isEmpty ? "暂无" : course.creditText)
                    LabeledContent("绩点", value: course.gradePointText.isEmpty ? "暂无" : course.gradePointText)
                    LabeledContent("成绩性质", value: course.scoreExamType.isEmpty ? "暂无" : course.scoreExamType)
                    LabeledContent("是否通过", value: course.isPassName.isEmpty ? "暂无" : course.isPassName)
                }

                Section("课程信息") {
                    LabeledContent("课程代码", value: course.courseCode.isEmpty ? "暂无" : course.courseCode)
                    LabeledContent("新课程代码", value: course.newCourseCode.isEmpty ? "暂无" : course.newCourseCode)
                    LabeledContent("课程类别", value: course.courseCategory.isEmpty ? "暂无" : course.courseCategory)
                    LabeledContent("更新时间", value: course.updateTimeText.isEmpty ? "暂无" : course.updateTimeText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("成绩详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }
}
