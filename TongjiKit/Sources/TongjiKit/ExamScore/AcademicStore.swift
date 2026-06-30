import Foundation
import SwiftData

@MainActor
public final class ExamScheduleStore: ObservableObject, CampusLocalStore {
    @Published public private(set) var exams: [ExamScheduleItem] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let context: ModelContext
    private let api: AcademicAPI

    public init(modelContext: ModelContext, api: AcademicAPI = AcademicAPI()) {
        self.context = modelContext
        self.api = api
        loadFromLocal()
    }

    public var scheduledExams: [ExamScheduleItem] {
        exams.filter(\.hasScheduledTime).sorted { lhs, rhs in
            (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
        }
    }

    public var unscheduledExams: [ExamScheduleItem] {
        exams.filter { !$0.hasScheduledTime }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public var nextExam: ExamScheduleItem? {
        let now = Date()
        return scheduledExams.first { ($0.endDate ?? $0.startDate ?? .distantPast) >= now }
    }

    public var lastSyncTime: Date? {
        exams.map(\.syncTime).max()
    }

    public var calendarName: String? {
        exams.first?.calendarName.nilIfEmpty
    }

    public var switchRemark: String? {
        exams.first?.switchRemark.nilIfEmpty
    }

    public func loadFromLocal() {
        let descriptor = FetchDescriptor<ExamScheduleItem>(
            sortBy: [
                SortDescriptor(\.sortIndex)
            ]
        )
        do {
            exams = try context.fetch(descriptor)
        } catch {
            exams = []
            lastError = error.localizedDescription
        }
    }

    public func sync() async {
        print("[ExamStore] 开始同步考试安排")
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        do {
            let result = try await api.fetchExams()
            let syncTime = Date()
            try clearAll()
            for (index, item) in result.items.enumerated() {
                context.insert(
                    ExamScheduleItem(
                        sourceId: item.sourceId,
                        calendarId: result.calendarId,
                        calendarName: result.calendarName,
                        switchRemark: result.switchRemark,
                        syncTime: syncTime,
                        sortIndex: index,
                        courseName: item.courseName,
                        newCourseCode: item.newCourseCode,
                        newTeachingClassCode: item.newTeachingClassCode,
                        examDateText: item.examDateText,
                        startTimeText: item.startTimeText,
                        endTimeText: item.endTimeText,
                        examSite: item.examSite,
                        examTimeText: item.examTimeText,
                        remark: item.remark,
                        examSituation: item.examSituation,
                        isOpen: item.isOpen
                    )
                )
            }
            try context.save()
            loadFromLocal()
            notifyDataDidChange()
            print("[ExamStore] 考试安排同步成功 count=\(exams.count) scheduled=\(scheduledExams.count)")
        } catch let error as AuthError {
            lastError = error.errorDescription
            let message = error.errorDescription ?? String(describing: error)
            print("[ExamStore] 考试安排同步失败 authError=\(message)")
        } catch {
            lastError = error.localizedDescription
            print("[ExamStore] 考试安排同步失败 error=\(error.localizedDescription)")
        }
    }

    public func clearError() {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = nil
        }
    }

    public func clearLocalData() {
        do {
            try clearAll()
            try context.save()
            exams = []
            lastError = nil
            notifyDataDidChange()
        } catch {
            exams = []
            lastError = error.localizedDescription
            notifyDataDidChange()
        }
    }

    private func clearAll() throws {
        let descriptor = FetchDescriptor<ExamScheduleItem>()
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
    }

    private func notifyDataDidChange() {
        NotificationCenter.default.post(name: .examScheduleDataDidChange, object: nil)
    }
}

@MainActor
public final class GradeStore: ObservableObject, CampusLocalStore {
    @Published public private(set) var summary: GradeSummarySnapshot?
    @Published public private(set) var courses: [GradeCourseRecord] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let context: ModelContext
    private let api: AcademicAPI

    public init(modelContext: ModelContext, api: AcademicAPI = AcademicAPI()) {
        self.context = modelContext
        self.api = api
        loadFromLocal()
    }

    public var terms: [GradeTermSummary] {
        let grouped = Dictionary(grouping: courses, by: \.termCode)
        return grouped.values.compactMap { records in
            guard let first = records.first else { return nil }
            return GradeTermSummary(
                termCode: first.termCode,
                termName: first.termName,
                calName: first.calName,
                averagePoint: first.termAveragePoint
            )
        }
        .sorted { $0.termCode < $1.termCode }
    }

    public var latestTerm: GradeTermSummary? {
        terms.last
    }

    public func courses(in term: GradeTermSummary) -> [GradeCourseRecord] {
        courses
            .filter { $0.termCode == term.termCode }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    public func loadFromLocal() {
        do {
            summary = try context.fetch(FetchDescriptor<GradeSummarySnapshot>()).first
            courses = try context.fetch(
                FetchDescriptor<GradeCourseRecord>(
                    sortBy: [
                        SortDescriptor(\.termCode),
                        SortDescriptor(\.sortIndex)
                    ]
                )
            )
        } catch {
            summary = nil
            courses = []
            lastError = error.localizedDescription
        }
    }

    public func sync() async {
        print("[GradeStore] 开始同步课程成绩")
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        do {
            let result = try await api.fetchGrades()
            let syncTime = Date()
            try clearAll()
            context.insert(
                GradeSummarySnapshot(
                    totalGradePoint: result.summary.totalGradePoint,
                    actualCredit: result.summary.actualCredit,
                    failingCredits: result.summary.failingCredits,
                    failingCourseCount: result.summary.failingCourseCount,
                    syncTime: syncTime
                )
            )
            for term in result.terms {
                for (index, course) in term.courses.enumerated() {
                    context.insert(
                        GradeCourseRecord(
                            sourceId: course.sourceId,
                            termCode: term.termCode,
                            termName: term.termName,
                            calName: term.calName,
                            termAveragePoint: term.averagePoint,
                            sortIndex: index,
                            courseCode: course.courseCode,
                            newCourseCode: course.newCourseCode,
                            courseName: course.courseName,
                            courseCategory: course.courseCategory,
                            creditText: course.creditText,
                            gradePointText: course.gradePointText,
                            scoreText: course.scoreText,
                            scoreExamType: course.scoreExamType,
                            publicCourseName: course.publicCourseName,
                            isPassName: course.isPassName,
                            updateTimeText: course.updateTimeText,
                            syncTime: syncTime
                        )
                    )
                }
            }
            try context.save()
            loadFromLocal()
            notifyDataDidChange()
            print("[GradeStore] 课程成绩同步成功 terms=\(terms.count) courses=\(courses.count)")
        } catch let error as AuthError {
            lastError = error.errorDescription
            let message = error.errorDescription ?? String(describing: error)
            print("[GradeStore] 课程成绩同步失败 authError=\(message)")
        } catch {
            lastError = error.localizedDescription
            print("[GradeStore] 课程成绩同步失败 error=\(error.localizedDescription)")
        }
    }

    public func clearError() {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = nil
        }
    }

    public func clearLocalData() {
        do {
            try clearAll()
            try context.save()
            summary = nil
            courses = []
            lastError = nil
            notifyDataDidChange()
        } catch {
            summary = nil
            courses = []
            lastError = error.localizedDescription
            notifyDataDidChange()
        }
    }

    private func clearAll() throws {
        for snapshot in try context.fetch(FetchDescriptor<GradeSummarySnapshot>()) {
            context.delete(snapshot)
        }
        for course in try context.fetch(FetchDescriptor<GradeCourseRecord>()) {
            context.delete(course)
        }
    }

    private func notifyDataDidChange() {
        NotificationCenter.default.post(name: .gradeReportDataDidChange, object: nil)
    }
}

public struct GradeTermSummary: Identifiable, Equatable, Hashable {
    public var id: Int { termCode }
    public let termCode: Int
    public let termName: String
    public let calName: String
    public let averagePoint: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
