import Foundation

/// 一系统课表 API 客户端。
///
/// 移植自 wish_drom `TongjiScheduleProvider.FetchDataAsync` /
/// `FetchCalendarIdAsync`：
/// - `GET https://1.tongji.edu.cn/api/baseresservice/schoolCalendar/currentTermCalendar` → 当前学期 calendarId
/// - `GET https://1.tongji.edu.cn/api/electionservice/reportManagement/findStudentTimetab?...` → 课表原始 JSON
///
/// 鉴权：`Cookie` + `X-Token: <sessionid>`。
///
/// 注意：wish_drom 中 BaseAddress 写的是 `https://1.tongji.edu.cn/workbench`，
/// 但 C# `HttpClient` 在相对路径以 `/` 开头时会丢弃 base 的 path，最终请求
/// 的是 `https://1.tongji.edu.cn/api/...`（**没有 /workbench 前缀**）。
/// 真实抓包确认这是后端实际的 API 路径。
public final class CourseAPI {

    private let apiHost = "https://1.tongji.edu.cn"
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    /// 拉取课表原始 JSON 字符串。
    public func fetchTimetableRaw() async throws -> String {
        guard let cookie = store.get(CredentialStore.Keys.tongjiCookies), !cookie.isEmpty else {
            throw AuthError.notLoggedIn("未找到登录凭证，请先完成登录")
        }
        let sessionId = store.get(CredentialStore.Keys.tongjiSessionId) ?? ""

        // 缺少 studentCode 则尝试用缓存的 uid/aesKey/aesIv 重新生成
        var studentCode = store.get(CredentialStore.Keys.tongjiStudentCode)
        if studentCode == nil || studentCode?.isEmpty == true {
            studentCode = try reEncryptStudentCode()
        }
        guard let studentCode, !studentCode.isEmpty else {
            throw AuthError.expired("缺少 studentCode，请重新登录以获取加密参数")
        }

        // 校历只描述“第几周对应哪一周日期”，同一学期内不需要每次同步都请求。
        // 当缓存缺失或本机日期已经超过缓存学期边界时，再向一系统刷新。
        var calendarId = cachedCalendarIdIfUsable()
        if calendarId == nil {
            calendarId = try await fetchCalendarId(cookie: cookie, sessionId: sessionId)
                ?? store.get(CredentialStore.Keys.tongjiCalendarId)
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let calendarParam = (calendarId ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // studentCode 已经过 encodeURIComponent，再次百分号编码会出错，故手动拼接 query。
        let finalURL = URL(string:
            "\(apiHost)/api/electionservice/reportManagement/findStudentTimetab" +
            "?calendarId=\(calendarParam)&studentCode=\(studentCode)&_t=\(timestamp)"
        )!

        var request = URLRequest(url: finalURL)
        applyAuthHeaders(&request, cookie: cookie, sessionId: sessionId)

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response)

        guard let str = String(data: data, encoding: .utf8) else {
            throw AuthError.loginFlowFailed("课表响应解码失败")
        }
        return str
    }

    /// 拉取当前学期 calendarId 并缓存元数据。
    public func refreshCalendarMetadata() async throws {
        guard let cookie = store.get(CredentialStore.Keys.tongjiCookies), !cookie.isEmpty else {
            throw AuthError.notLoggedIn("未找到登录凭证，请先完成登录")
        }
        let sessionId = store.get(CredentialStore.Keys.tongjiSessionId) ?? ""
        _ = try await fetchCalendarId(cookie: cookie, sessionId: sessionId)
    }

    /// 拉取当前学期 calendarId 并缓存元数据。
    public func fetchCalendarId(cookie: String, sessionId: String) async throws -> String? {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string:
            "\(apiHost)/api/baseresservice/schoolCalendar/currentTermCalendar?_t=\(timestamp)"
        )!
        var request = URLRequest(url: url)
        applyAuthHeaders(&request, cookie: cookie, sessionId: sessionId)

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response)

        guard let content = String(data: data, encoding: .utf8) else { return nil }
        cacheCalendarMetadata(content)

        let calendarId = JSONUtils.extractNestedField(
            content, path: ["data", "schoolCalendar", "id"]
        )
        if let calendarId, !calendarId.isEmpty {
            store.set(calendarId, for: CredentialStore.Keys.tongjiCalendarId)
        }
        return calendarId
    }

    private func cacheCalendarMetadata(_ json: String) {
        if let beginDay = JSONUtils.extractNestedField(json, path: ["data", "schoolCalendar", "beginDay"]) {
            store.set(beginDay, for: CredentialStore.Keys.tongjiCalendarBeginDayMs)
        }
        if let endDay = JSONUtils.extractNestedField(json, path: ["data", "schoolCalendar", "endDay"]) {
            store.set(endDay, for: CredentialStore.Keys.tongjiCalendarEndDayMs)
        }
        if let weekNum = JSONUtils.extractNestedField(json, path: ["data", "schoolCalendar", "weekNum"]) {
            store.set(weekNum, for: CredentialStore.Keys.tongjiCalendarWeekNum)
        }
        if let week = JSONUtils.extractNestedField(json, path: ["data", "week"]) {
            store.set(week, for: CredentialStore.Keys.tongjiCalendarCurrentWeek)
        }
        if let simpleName = JSONUtils.extractNestedField(json, path: ["data", "simpleName"]) {
            store.set(simpleName, for: CredentialStore.Keys.tongjiCalendarSimpleName)
        }
        if let s = JSONUtils.extractNestedField(json, path: ["data", "schoolCalendar", "teachingWeekStart"]) {
            store.set(s, for: CredentialStore.Keys.tongjiTeachingWeekStart)
        }
        if let s = JSONUtils.extractNestedField(json, path: ["data", "schoolCalendar", "teachingWeekEnd"]) {
            store.set(s, for: CredentialStore.Keys.tongjiTeachingWeekEnd)
        }
        if let s = JSONUtils.extractNestedField(json, path: ["data", "schoolCalendar", "examWeekStart"]) {
            store.set(s, for: CredentialStore.Keys.tongjiExamWeekStart)
        }
        if let s = JSONUtils.extractNestedField(json, path: ["data", "schoolCalendar", "examWeekEnd"]) {
            store.set(s, for: CredentialStore.Keys.tongjiExamWeekEnd)
        }
    }

    private func cachedCalendarIdIfUsable() -> String? {
        guard let calendarId = store.get(CredentialStore.Keys.tongjiCalendarId),
              !calendarId.isEmpty,
              let beginDayText = store.get(CredentialStore.Keys.tongjiCalendarBeginDayMs),
              Double(beginDayText) != nil,
              let weekNumText = store.get(CredentialStore.Keys.tongjiCalendarWeekNum),
              Int(weekNumText) != nil else {
            return nil
        }

        guard let endDayText = store.get(CredentialStore.Keys.tongjiCalendarEndDayMs),
              let endDayMs = Double(endDayText) else {
            return calendarId
        }

        let nowMs = Date().timeIntervalSince1970 * 1000
        return nowMs <= endDayMs ? calendarId : nil
    }

    private func reEncryptStudentCode() throws -> String? {
        guard let uid = store.get(CredentialStore.Keys.tongjiUid),
              let aesKey = store.get(CredentialStore.Keys.tongjiAesKey),
              let aesIv = store.get(CredentialStore.Keys.tongjiAesIv) else {
            return nil
        }
        let encrypted = try StudentCodeCipher.encryptStudentCode(uid: uid, aesKey: aesKey, aesIv: aesIv)
        store.set(encrypted, for: CredentialStore.Keys.tongjiStudentCode)
        return encrypted
    }

    private func applyAuthHeaders(_ request: inout URLRequest, cookie: String, sessionId: String) {
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Token")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15
    }

    private func ensureAuth(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            store.remove(CredentialStore.Keys.tongjiCookies)
            store.remove(CredentialStore.Keys.tongjiSessionId)
            throw AuthError.expired("凭证已失效，请重新登录")
        }
        if !(200..<300).contains(http.statusCode) {
            throw AuthError.loginFlowFailed("HTTP \(http.statusCode)")
        }
    }
}
