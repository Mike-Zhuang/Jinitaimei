import Foundation

public final class AcademicAPI {
    private let apiHost = "https://1.tongji.edu.cn"
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func fetchExams() async throws -> TongjiExamFetchResult {
        try await withAuthRetry { [self] in
            try await fetchExamsOnce()
        }
    }

    public func fetchGrades() async throws -> TongjiGradeFetchResult {
        try await withAuthRetry { [self] in
            try await fetchGradesOnce()
        }
    }

    private func fetchExamsOnce() async throws -> TongjiExamFetchResult {
        try await switchCurrentAuthId(9102)
        let calendar = try await fetchExamCalendar()
        let items = try await fetchExamItems(calendarId: calendar.calendarId)
        return TongjiExamFetchResult(
            calendarId: calendar.calendarId,
            calendarName: calendar.calendarName,
            switchRemark: items.switchRemark,
            items: items.items
        )
    }

    private func fetchGradesOnce() async throws -> TongjiGradeFetchResult {
        guard let studentId = store.get(CredentialStore.Keys.tongjiUid), !studentId.isEmpty else {
            throw AuthError.notLoggedIn("缺少学号，请重新登录校园账户")
        }
        try await switchCurrentAuthId(12174)
        let tags = try await fetchCourseTags(studentId: studentId)
        return try await fetchGradeSummary(studentId: studentId, tags: tags)
    }

    private func switchCurrentAuthId(_ authId: Int) async throws {
        let url = URL(string: "\(apiHost)/api/sessionservice/session/currentAuthId")!
        var request = try authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(CurrentAuthRequest(authId: authId))

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response, url: url)
        let payload = try JSONDecoder().decode(CurrentAuthResponse.self, from: data)
        guard payload.code == 200 else {
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "切换教务上下文失败" : payload.msg)
        }
    }

    private func fetchExamCalendar() async throws -> ExamCalendarInfo {
        let url = URL(string:
            "\(apiHost)/api/electionservice/underGraduateExamSwitch/getExamCalendar?examType=1&switchType=null"
        )!
        var request = try authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("1".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response, url: url)
        let payload = try JSONDecoder().decode(ExamCalendarResponse.self, from: data)
        guard payload.code == 200, let calendar = payload.data else {
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "考试学期响应异常" : payload.msg)
        }
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
            let url = URL(string: "\(apiHost)/api/electionservice/undergraduateExamQuery/getStudentListPage")!
            var request = try authorizedRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(
                ExamListRequest(
                    pageNum: page,
                    pageSize: 20,
                    condition: ExamListCondition(calendarId: calendarId, examSituation: "", examType: 1)
                )
            )

            let (data, response) = try await session.data(for: request)
            try ensureAuth(response: response, url: url)
            let payload = try JSONDecoder().decode(ExamListResponse.self, from: data)
            guard payload.code == 200, let wrapper = payload.data else {
                throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "考试安排响应异常" : payload.msg)
            }

            if switchRemark.isEmpty {
                switchRemark = wrapper.switchRrmark ?? ""
            }
            let pageData = wrapper.data
            all.append(contentsOf: pageData.list.map { row in
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
            })

            guard pageData.pageNum * pageData.pageSize < pageData.total else { break }
            page += 1
        }

        return ExamItemsResult(switchRemark: switchRemark, items: all)
    }

    private func fetchCourseTags(studentId: String) async throws -> [String: String] {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string:
            "\(apiHost)/api/scoremanagementservice/studentScoreBk/queryCourseTag?studentId=\(studentId)&_t=\(timestamp)"
        )!
        var request = try authorizedRequest(url: url)
        request.setValue("\(apiHost)/oldStysteMyGrades", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response, url: url)
        let payload = try JSONDecoder().decode(CourseTagResponse.self, from: data)
        guard payload.code == 200 else {
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
        return result
    }

    private func fetchGradeSummary(studentId: String, tags: [String: String]) async throws -> TongjiGradeFetchResult {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string:
            "\(apiHost)/api/scoremanagementservice/scoreGrades/getMyGrades?studentId=\(studentId)&_t=\(timestamp)"
        )!
        var request = try authorizedRequest(url: url)
        request.setValue("\(apiHost)/oldStysteMyGrades", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response, url: url)
        let payload = try JSONDecoder().decode(GradeResponse.self, from: data)
        guard payload.code == 200, let data = payload.data else {
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "成绩响应异常" : payload.msg)
        }

        return TongjiGradeFetchResult(
            summary: TongjiGradeSummary(
                totalGradePoint: data.totalGradePoint ?? "",
                actualCredit: data.actualCredit ?? "",
                failingCredits: data.failingCredits ?? "",
                failingCourseCount: data.failingCourseCount ?? ""
            ),
            terms: (data.term ?? []).map { term in
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

    private func authorizedRequest(url: URL) throws -> URLRequest {
        guard let cookie = currentCookieHeader(), !cookie.isEmpty else {
            throw AuthError.notLoggedIn("未找到登录凭证，请先在设置中登录校园账户")
        }
        let sessionId = store.get(CredentialStore.Keys.tongjiSessionId) ?? ""
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Token")
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(apiHost, forHTTPHeaderField: "Origin")
        request.setValue("\(apiHost)/workbench", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20
        return request
    }

    private func currentCookieHeader() -> String? {
        let host = URL(string: apiHost)!
        let fromJar = CookieJar.shared.loadHeader(for: host)
        if !fromJar.isEmpty { return fromJar }
        return store.get(CredentialStore.Keys.tongjiCookies)
    }

    private func ensureAuth(response: URLResponse, url: URL) throws {
        if let http = response as? HTTPURLResponse,
           let fields = http.allHeaderFields as? [String: String] {
            CookieJar.shared.mergeSetCookieFields(fields, for: url)
        }
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AuthError.expired("凭证已失效")
        }
        if !(200..<300).contains(http.statusCode) {
            throw AuthError.loginFlowFailed("HTTP \(http.statusCode)")
        }
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

private struct CurrentAuthRequest: Encodable {
    let authId: Int
}

private struct CurrentAuthResponse: Decodable {
    let code: Int
    let msg: String
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
