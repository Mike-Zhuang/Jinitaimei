import Foundation

public final class AcademicAPI {
    private let apiHost = "https://1.tongji.edu.cn"
    private let store: CredentialStore
    private let httpClient: TongjiHTTPClient

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.httpClient = TongjiHTTPClient(store: store, session: session)
    }

    public func fetchExams() async throws -> TongjiExamFetchResult {
        print("[AcademicAPI] 开始同步考试安排")
        return try await withAuthRetry { [self] in
            try await fetchExamsOnce()
        }
    }

    public func fetchGrades() async throws -> TongjiGradeFetchResult {
        print("[AcademicAPI] 开始同步课程成绩")
        return try await withAuthRetry { [self] in
            try await fetchGradesOnce()
        }
    }

    private func fetchExamsOnce() async throws -> TongjiExamFetchResult {
        print("[AcademicAPI] 考试：切换一系统上下文 authId=\(TongjiHTTPClient.OneSystemAuthContext.examSchedule.rawValue)")
        try await httpClient.switchOneSystemAuthContext(.examSchedule)
        let calendar = try await fetchExamCalendar()
        print("[AcademicAPI] 考试：使用学期 calendarId=\(calendar.calendarId) name=\(calendar.calendarName)")
        let items = try await fetchExamItems(calendarId: calendar.calendarId)
        let scheduledCount = items.items.filter {
            !$0.examDateText.isEmpty && !$0.startTimeText.isEmpty && !$0.endTimeText.isEmpty
        }.count
        print("[AcademicAPI] 考试：同步完成 scheduled=\(scheduledCount) total=\(items.items.count)")
        return TongjiExamFetchResult(
            calendarId: calendar.calendarId,
            calendarName: calendar.calendarName,
            switchRemark: items.switchRemark,
            items: items.items
        )
    }

    private func fetchGradesOnce() async throws -> TongjiGradeFetchResult {
        guard let studentId = store.get(CredentialStore.Keys.tongjiUid), !studentId.isEmpty else {
            print("[AcademicAPI] 成绩：缺少学号，无法发起请求")
            throw AuthError.notLoggedIn("缺少学号，请重新登录校园账户")
        }
        print("[AcademicAPI] 成绩：切换一系统上下文 authId=\(TongjiHTTPClient.OneSystemAuthContext.gradeReport.rawValue) studentIdLen=\(studentId.count)")
        try await httpClient.switchOneSystemAuthContext(.gradeReport)
        let tags = try await fetchCourseTags(studentId: studentId)
        print("[AcademicAPI] 成绩：课程标签映射 count=\(tags.count)")
        return try await fetchGradeSummary(studentId: studentId, tags: tags)
    }

    private func fetchExamCalendar() async throws -> ExamCalendarInfo {
        print("[AcademicAPI] 考试：请求考试学期")
        let request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/electionservice/underGraduateExamSwitch/getExamCalendar?examType=1&switchType=null",
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data("1".utf8)
        )

        let data = try await httpClient.data(for: request, endpoint: .oneSystem)
        let payload = try JSONDecoder().decode(ExamCalendarResponse.self, from: data)
        guard payload.code == 200, let calendar = payload.data else {
            print("[AcademicAPI] 考试学期响应异常 code=\(payload.code) msg=\(payload.msg.isEmpty ? "<empty>" : payload.msg)")
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "考试学期响应异常" : payload.msg)
        }
        print("[AcademicAPI] 考试学期获取成功 calendarId=\(calendar.calendarId) name=\(calendar.calendarIdI18n)")
        return ExamCalendarInfo(
            calendarId: calendar.calendarId,
            calendarName: calendar.calendarIdI18n
        )
    }

    private func fetchExamItems(calendarId: Int) async throws -> ExamItemsResult {
        var page = 1
        var all: [TongjiExamItem] = []
        var switchRemark = ""

        while true {
            print("[AcademicAPI] 考试：请求列表 calendarId=\(calendarId) page=\(page)")
            let body = try JSONEncoder().encode(
                ExamListRequest(
                    pageNum: page,
                    pageSize: 20,
                    condition: ExamListCondition(calendarId: calendarId, examSituation: "", examType: 1)
                )
            )
            let request = try httpClient.request(
                endpoint: .oneSystem,
                path: "/api/electionservice/undergraduateExamQuery/getStudentListPage",
                method: "POST",
                body: body
            )

            let data = try await httpClient.data(for: request, endpoint: .oneSystem)
            let payload = try JSONDecoder().decode(ExamListResponse.self, from: data)
            guard payload.code == 200, let wrapper = payload.data else {
                print("[AcademicAPI] 考试列表响应异常 page=\(page) code=\(payload.code) msg=\(payload.msg.isEmpty ? "<empty>" : payload.msg)")
                throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "考试安排响应异常" : payload.msg)
            }

            if switchRemark.isEmpty {
                switchRemark = wrapper.switchRrmark ?? ""
            }
            let pageData = wrapper.data
            let mapped = pageData.list.map { row in
                TongjiExamItem(
                    sourceId: row.id ?? stableId(row.newCourseCode, row.newTeachingClassCode, row.courseName),
                    courseName: row.courseName ?? "",
                    newCourseCode: row.newCourseCode ?? "",
                    newTeachingClassCode: row.newTeachingClassCode ?? "",
                    examDateText: row.examDate ?? "",
                    startTimeText: row.startTime ?? "",
                    endTimeText: row.endTime ?? "",
                    examSite: row.examSite ?? "",
                    examTimeText: row.examTime ?? "",
                    remark: row.remark ?? "",
                    examSituation: row.examSituation ?? 0,
                    isOpen: row.isOpen ?? 0
                )
            }
            all.append(contentsOf: mapped)
            print("[AcademicAPI] 考试：列表 page=\(pageData.pageNum) count=\(mapped.count) total=\(pageData.total) cumulative=\(all.count)")

            guard pageData.pageNum * pageData.pageSize < pageData.total else { break }
            page += 1
        }

        return ExamItemsResult(switchRemark: switchRemark, items: all)
    }

    private func fetchCourseTags(studentId: String) async throws -> [String: String] {
        print("[AcademicAPI] 成绩：请求课程标签 studentIdLen=\(studentId.count)")
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/scoremanagementservice/studentScoreBk/queryCourseTag",
            queryItems: [
                URLQueryItem(name: "studentId", value: studentId),
                URLQueryItem(name: "_t", value: "\(timestamp)")
            ],
            headers: ["Referer": "\(apiHost)/oldStysteMyGrades"]
        )

        let data = try await httpClient.data(for: request, endpoint: .oneSystem)
        let payload = try JSONDecoder().decode(CourseTagResponse.self, from: data)
        guard payload.code == 200 else {
            print("[AcademicAPI] 课程标签响应异常 code=\(payload.code) msg=\(payload.msg.isEmpty ? "<empty>" : payload.msg)")
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "课程标签响应异常" : payload.msg)
        }
        var result: [String: String] = [:]
        for (index, tag) in (payload.data ?? []).enumerated() {
            let name = tag.shortName?.nilIfEmpty ?? tag.nameCN?.nilIfEmpty
            if let name {
                // courseLabName 里括号值有两种形态：有的直接是前端红圈序号，有的是后端 tag.id。
                // 例如"科学探索与生命关怀[2]"按序号映射，"人文经典与审美素养[125]"按 tag.id 映射。
                result[String(index + 1)] = name
                result[String(tag.id)] = name
            }
        }
        print("[AcademicAPI] 成绩：课程标签获取成功 rawCount=\(payload.data?.count ?? 0) mapCount=\(result.count)")
        return result
    }

    private func fetchGradeSummary(studentId: String, tags: [String: String]) async throws -> TongjiGradeFetchResult {
        print("[AcademicAPI] 成绩：请求成绩汇总 studentIdLen=\(studentId.count) tagCount=\(tags.count)")
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/scoremanagementservice/scoreGrades/getMyGrades",
            queryItems: [
                URLQueryItem(name: "studentId", value: studentId),
                URLQueryItem(name: "_t", value: "\(timestamp)")
            ],
            headers: ["Referer": "\(apiHost)/oldStysteMyGrades"]
        )

        let data = try await httpClient.data(for: request, endpoint: .oneSystem)
        let payload = try JSONDecoder().decode(GradeResponse.self, from: data)
        guard payload.code == 200, let data = payload.data else {
            print("[AcademicAPI] 成绩汇总响应异常 code=\(payload.code) msg=\(payload.msg.isEmpty ? "<empty>" : payload.msg)")
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "成绩响应异常" : payload.msg)
        }
        let terms = data.term ?? []
        let courseCount = terms.reduce(0) { partial, term in
            partial + (term.creditInfo?.count ?? 0)
        }
        print("[AcademicAPI] 成绩：汇总获取成功 terms=\(terms.count) courses=\(courseCount) hasGPA=\((data.totalGradePoint ?? "").isEmpty == false) hasCredit=\((data.actualCredit ?? "").isEmpty == false)")

        return TongjiGradeFetchResult(
            summary: TongjiGradeSummary(
                totalGradePoint: data.totalGradePoint ?? "",
                actualCredit: data.actualCredit ?? "",
                failingCredits: data.failingCredits ?? "",
                failingCourseCount: data.failingCourseCount ?? ""
            ),
            terms: terms.map { term in
                TongjiGradeTerm(
                    termCode: term.termcode ?? 0,
                    termName: term.termName ?? "",
                    calName: term.calName ?? "",
                    averagePoint: term.averagePoint ?? "",
                    courses: (term.creditInfo ?? []).map { course in
                        let publicCourseName = course.publicCoursesName ?? ""
                        let category = Self.courseCategory(from: course.courseLabName, tags: tags)
                            ?? (publicCourseName == "必修" ? nil : publicCourseName.nilIfEmpty)
                            ?? ""
                        return TongjiGradeCourse(
                            sourceId: course.id ?? stableId(course.newCourseCode, course.courseCode, course.courseName),
                            courseCode: course.courseCode ?? "",
                            newCourseCode: course.newCourseCode ?? "",
                            courseName: course.courseName ?? "",
                            courseCategory: category,
                            creditText: Self.cleanNumber(course.credit),
                            gradePointText: Self.cleanNumber(course.gradePoint),
                            scoreText: course.scoreName?.nilIfEmpty ?? course.score ?? "",
                            scoreExamType: course.scoreEaxmTypeI18n ?? "",
                            publicCourseName: course.publicCoursesName ?? "",
                            isPassName: course.isPassName ?? "",
                            updateTimeText: course.updateTime ?? ""
                        )
                    }
                )
            }
        )
    }

    private static func cleanNumber(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private static func courseCategory(from value: String?, tags: [String: String]) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        if let code = bracketCode(in: value), let mapped = tags[code] {
            let label = removingBracketCode(from: value)
            if let label = label.nilIfEmpty {
                return "\(label) · \(mapped)"
            }
            return mapped
        }
        let cleaned = value
            .replacingOccurrences(of: "[", with: "（")
            .replacingOccurrences(of: "]", with: "）")
        return cleaned.nilIfEmpty
    }

    private static func bracketCode(in value: String) -> String? {
        let pattern = #"(?:\[|（|\()(\d+)(?:\]|）|\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }

    private static func removingBracketCode(from value: String) -> String {
        let pattern = #"\s*(?:\[|（|\()\d+(?:\]|）|\))\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        let cleaned = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stableId(_ values: String?...) -> Int {
        let joined = values.compactMap { $0 }.joined(separator: "|")
        return abs(joined.hashValue)
    }
}

private struct ExamCalendarInfo {
    let calendarId: Int
    let calendarName: String
}

private struct ExamItemsResult {
    let switchRemark: String
    let items: [TongjiExamItem]
}

private struct ExamCalendarResponse: Decodable {
    let code: Int
    let msg: String
    let data: ExamCalendarData?
}

private struct ExamCalendarData: Decodable {
    let calendarId: Int
    let calendarIdI18n: String
}

private struct ExamListRequest: Encodable {
    let pageNum: Int
    let pageSize: Int
    let condition: ExamListCondition

    enum CodingKeys: String, CodingKey {
        case pageNum = "pageNum_"
        case pageSize = "pageSize_"
        case condition
    }
}

private struct ExamListCondition: Encodable {
    let calendarId: Int
    let examSituation: String
    let examType: Int
}

private struct ExamListResponse: Decodable {
    let code: Int
    let msg: String
    let data: ExamListWrapper?
}

private struct ExamListWrapper: Decodable {
    let switchRrmark: String?
    let data: ExamListPage
}

private struct ExamListPage: Decodable {
    let pageNum: Int
    let pageSize: Int
    let total: Int
    let list: [ExamRow]

    enum CodingKeys: String, CodingKey {
        case pageNum = "pageNum_"
        case pageSize = "pageSize_"
        case total = "total_"
        case list
    }
}

private struct ExamRow: Decodable {
    let id: Int?
    let newCourseCode: String?
    let newTeachingClassCode: String?
    let courseName: String?
    let examDate: String?
    let startTime: String?
    let endTime: String?
    let examSite: String?
    let examTime: String?
    let remark: String?
    let examSituation: Int?
    let isOpen: Int?
}

private struct CourseTagResponse: Decodable {
    let code: Int
    let msg: String
    let data: [CourseTagRow]?
}

private struct CourseTagRow: Decodable {
    let id: Int
    let shortName: String?
    let nameCN: String?
}

private struct GradeResponse: Decodable {
    let code: Int
    let msg: String
    let data: GradeData?
}

private struct GradeData: Decodable {
    let totalGradePoint: String?
    let actualCredit: String?
    let failingCredits: String?
    let failingCourseCount: String?
    let term: [GradeTermRow]?
}

private struct GradeTermRow: Decodable {
    let termcode: Int?
    let termName: String?
    let calName: String?
    let averagePoint: String?
    let creditInfo: [GradeCourseRow]?
}

private struct GradeCourseRow: Decodable {
    let id: Int?
    let courseCode: String?
    let newCourseCode: String?
    let courseName: String?
    let courseLabel: String?
    let courseLabName: String?
    let credit: Double?
    let gradePoint: Double?
    let score: String?
    let scoreName: String?
    let scoreEaxmTypeI18n: String?
    let publicCoursesName: String?
    let publicCoursesType: String?
    let courseNature: String?
    let isPassName: String?
    let updateTime: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
