import Foundation

/// 一系统课表 API 客户端。
///
/// 移植自 wish_drom `TongjiScheduleProvider`，鉴权：`Cookie` + `X-Token: <sessionid>`。
///
/// 公方法 `fetchTimetableRaw` / `refreshCalendarMetadata` 均自带 `withAuthRetry`，
/// 401/403 一次自动续期；ensureAuth **不再** `store.remove`。
public final class CourseAPI {

    private let store: CredentialStore
    private let httpClient: TongjiHTTPClient

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.httpClient = TongjiHTTPClient(store: store, session: session)
    }

    public func fetchTimetableRaw() async throws -> String {
        try await withAuthRetry { [self] in
            try await fetchTimetableRawOnce()
        }
    }

    public func refreshCalendarMetadata() async throws {
        try await withAuthRetry { [self] in
            try await refreshCalendarMetadataOnce()
        }
    }

    // MARK: - Once 版本（不重试，专供内部 / 续期流程使用）

    public func fetchTimetableRawOnce() async throws -> String {
        var studentCode = store.get(CredentialStore.Keys.tongjiStudentCode)
        if studentCode == nil || studentCode?.isEmpty == true {
            studentCode = try reEncryptStudentCode()
        }
        guard let studentCode, !studentCode.isEmpty else {
            throw AuthError.expired("缺少 studentCode，请重新登录以获取加密参数")
        }

        var calendarId = cachedCalendarIdIfUsable()
        if calendarId == nil {
            calendarId = try await fetchCalendarIdOnce()
                ?? store.get(CredentialStore.Keys.tongjiCalendarId)
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let calendarParam = (calendarId ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/electionservice/reportManagement/findStudentTimetab?calendarId=\(calendarParam)&studentCode=\(studentCode)&_t=\(timestamp)",
            timeout: 15
        )

        let data = try await httpClient.data(for: request, endpoint: .oneSystem)

        guard let str = String(data: data, encoding: .utf8) else {
            throw AuthError.loginFlowFailed("课表响应解码失败")
        }
        return str
    }

    public func refreshCalendarMetadataOnce() async throws {
        _ = try await fetchCalendarIdOnce()
    }

    @discardableResult
    private func fetchCalendarIdOnce() async throws -> String? {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/baseresservice/schoolCalendar/currentTermCalendar",
            queryItems: [URLQueryItem(name: "_t", value: "\(timestamp)")],
            headers: ["Accept": "application/json"],
            timeout: 15
        )

        let data = try await httpClient.data(for: request, endpoint: .oneSystem)

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

    // MARK: - 辅助

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

}
