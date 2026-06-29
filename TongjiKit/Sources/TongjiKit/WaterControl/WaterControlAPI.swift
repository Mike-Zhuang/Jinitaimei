import Foundation
import os.log

public final class WaterControlAPI: @unchecked Sendable {
    private let baseURL = URL(string: "https://ks.tongji.edu.cn")!
    private let store: CredentialStore
    private let session: URLSession
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "WaterControlAPI")
    private var cachedToken: String?
    private let tokenFreshnessInterval: TimeInterval = 6 * 60 * 60

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
        self.cachedToken = store.get(CredentialStore.Keys.waterControlApiToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public func clearCachedToken() {
        cachedToken = nil
        store.remove(CredentialStore.Keys.waterControlApiToken)
        store.remove(CredentialStore.Keys.waterControlApiTokenSavedAt)
    }

    public func fetchGroups() async throws -> [WaterControlGroup] {
        logger.debug("[Water] 开始获取水控分组")
        let payload: WaterGroupResponse = try await perform(path: "/waterapi/api/UseHzWatch")
        try validate(retNo: payload.retNo, message: payload.retDsp, operation: "获取水控分组")
        logger.debug("[Water] 水控分组获取成功 count=\(payload.list.count, privacy: .public)")
        return payload.list.map { $0.asGroup() }
    }

    public func fetchControllers(for group: WaterControlGroup) async throws -> [WaterControlDevice] {
        logger.debug("[Water] 开始获取控水器 groupId=\(group.id, privacy: .public) groupName=\(group.name, privacy: .public)")
        let params = try authParams()
        let token = try await token(for: params)
        let info = try WaterControlCipher.encryptInfo(
            [
                "ano": params.account,
                "groupid": group.id
            ],
            keyBase64: params.aesKey
        )
        logger.debug("[Water] 控水器请求参数已生成 groupId=\(group.id, privacy: .public) variant=encrypted-groupid infoLen=\(info.count, privacy: .public) tokenLen=\(token.count, privacy: .public)")
        var payload: WaterControllerResponse = try await perform(
            path: "/waterapi/api/AccUseHzWatch",
            queryItems: [
                URLQueryItem(name: "info", value: info),
                URLQueryItem(name: "token", value: token)
            ]
        )
        if payload.retNo != 0,
           let message = payload.retDsp,
           Self.isReservationRestricted(message: message) {
            payload = try await retryControllerCompatibilityVariants(
                params: params,
                token: token,
                group: group,
                currentPayload: payload
            )
        }
        do {
            try validate(retNo: payload.retNo, message: payload.retDsp, operation: "获取水控器")
        } catch let error as AuthError where error.isExpired {
            clearCachedToken()
            throw error
        }
        logger.debug("[Water] 控水器获取成功 groupId=\(group.id, privacy: .public) count=\(payload.list.count, privacy: .public)")
        return payload.list.map { $0.asDevice(group: group) }
    }

    private func retryControllerCompatibilityVariants(
        params: WaterControlAuthParams,
        token: String,
        group: WaterControlGroup,
        currentPayload: WaterControllerResponse
    ) async throws -> WaterControllerResponse {
        var lastPayload = currentPayload
        let variants = try controllerCompatibilityVariants(params: params, token: token, group: group)
        for variant in variants {
            logger.debug("[Water] 控水器请求被限制，尝试兼容分支 groupId=\(group.id, privacy: .public) variant=\(variant.name, privacy: .public)")
            do {
                let payload: WaterControllerResponse = try await perform(
                    path: "/waterapi/api/AccUseHzWatch",
                    queryItems: variant.queryItems
                )
                logger.debug("[Water] 控水器兼容分支响应 groupId=\(group.id, privacy: .public) variant=\(variant.name, privacy: .public) ret=\(payload.retNo, privacy: .public) msg=\(Self.redacted(payload.retDsp), privacy: .public) count=\(payload.list.count, privacy: .public)")
                lastPayload = payload
                if payload.retNo == 0 {
                    return payload
                }
            } catch {
                logger.debug("[Water] 控水器兼容分支失败 groupId=\(group.id, privacy: .public) variant=\(variant.name, privacy: .public) error=\(Self.redacted(error.localizedDescription), privacy: .public)")
            }
        }
        return lastPayload
    }

    private func controllerCompatibilityVariants(
        params: WaterControlAuthParams,
        token: String,
        group: WaterControlGroup
    ) throws -> [ControllerRequestVariant] {
        let encryptedClassNo = try WaterControlCipher.encryptInfo(
            [
                "ano": params.account,
                "classno": group.id
            ],
            keyBase64: params.aesKey
        )
        return [
            ControllerRequestVariant(
                name: "encrypted-classno",
                queryItems: [
                    URLQueryItem(name: "info", value: encryptedClassNo),
                    URLQueryItem(name: "token", value: token)
                ]
            ),
            ControllerRequestVariant(
                name: "plain-groupid",
                queryItems: [
                    URLQueryItem(name: "ano", value: params.account),
                    URLQueryItem(name: "groupid", value: group.id),
                    URLQueryItem(name: "token", value: token)
                ]
            ),
            ControllerRequestVariant(
                name: "plain-classno",
                queryItems: [
                    URLQueryItem(name: "ano", value: params.account),
                    URLQueryItem(name: "classno", value: group.id),
                    URLQueryItem(name: "token", value: token)
                ]
            )
        ]
    }

    private func fetchControllersViaWebView(
        info: String,
        token: String,
        group: WaterControlGroup
    ) async throws -> WaterControllerResponse {
        let data = try await WaterAuthCoordinator.shared.fetchKSData(
            path: "/waterapi/api/AccUseHzWatch",
            queryItems: [
                URLQueryItem(name: "info", value: info),
                URLQueryItem(name: "token", value: token)
            ]
        )
        let payload = try JSONDecoder().decode(WaterControllerResponse.self, from: data)
        logger.debug("[Water] WebView 同源控水器响应 groupId=\(group.id, privacy: .public) ret=\(payload.retNo, privacy: .public) msg=\(Self.redacted(payload.retDsp), privacy: .public) count=\(payload.list.count, privacy: .public)")
        return payload
    }

    private func token(for params: WaterControlAuthParams) async throws -> String {
        if let token = reusableToken(allowStale: false) {
            logger.debug("[Water] 复用水控 Token len=\(token.count, privacy: .public)")
            return token
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: Date())
        let aesSource = params.aesKey == WaterControlCipher.defaultAesKey ? "fallback" : "js"
        let passwordSource = params.password == WaterControlCipher.defaultPassword ? "fallback" : "js"
        logger.debug("[Water] 准备获取水控 Token accountLen=\(params.account.count, privacy: .public) aes=\(aesSource, privacy: .public) password=\(passwordSource, privacy: .public) timeLen=\(timestamp.count, privacy: .public)")
        let info = try WaterControlCipher.encryptInfo(
            [
                "userid": params.account,
                "userpassword": params.password,
                "time": timestamp
            ],
            keyBase64: params.aesKey
        )
        logger.debug("[Water] GetToken info 已生成 infoLen=\(info.count, privacy: .public)")
        var payload: WaterTokenResponse = try await perform(
            path: "/waterapi/api/GetToken",
            queryItems: [URLQueryItem(name: "info", value: info)]
        )
        if payload.retNo != 0,
           let message = payload.retDsp,
           Self.isReservationRestricted(message: message) {
            logger.debug("[Water] URLSession GetToken 被限制，尝试 WebView 同源兜底")
            do {
                payload = try await fetchTokenViaWebView(info: info)
            } catch {
                logger.debug("[Water] WebView 同源 GetToken 兜底失败 error=\(Self.redacted(error.localizedDescription), privacy: .public)")
            }
        }
        do {
            try validate(retNo: payload.retNo, message: payload.retDsp, operation: "获取水控 Token")
        } catch let error as AuthError {
            if let token = reusableToken(allowStale: true) {
                logger.debug("[Water] GetToken 失败但存在历史 Token，尝试复用 len=\(token.count, privacy: .public) error=\(Self.redacted(error.errorDescription), privacy: .public)")
                return token
            }
            throw error
        }
        guard let token = payload.token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw AuthError.expired("水控 Token 为空")
        }
        storeToken(token)
        logger.debug("[Water] 水控 Token 获取成功 len=\(token.count, privacy: .public)")
        return token
    }

    private func fetchTokenViaWebView(info: String) async throws -> WaterTokenResponse {
        let data = try await WaterAuthCoordinator.shared.fetchKSData(
            path: "/waterapi/api/GetToken",
            queryItems: [URLQueryItem(name: "info", value: info)]
        )
        let payload = try JSONDecoder().decode(WaterTokenResponse.self, from: data)
        logger.debug("[Water] WebView 同源 GetToken 响应 ret=\(payload.retNo, privacy: .public) msg=\(Self.redacted(payload.retDsp), privacy: .public) tokenLen=\(payload.token?.count ?? 0, privacy: .public)")
        return payload
    }

    private func reusableToken(allowStale: Bool) -> String? {
        guard let token = store.get(CredentialStore.Keys.waterControlApiToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            if let cachedToken, !cachedToken.isEmpty {
                return cachedToken
            }
            return nil
        }
        if !allowStale, let savedAt = tokenSavedAt(), Date().timeIntervalSince(savedAt) > tokenFreshnessInterval {
            logger.debug("[Water] 历史水控 Token 已超过新鲜期，先尝试重新获取")
            return nil
        }
        cachedToken = token
        return token
    }

    private func storeToken(_ token: String) {
        cachedToken = token
        store.set(token, for: CredentialStore.Keys.waterControlApiToken)
        store.set(String(Date().timeIntervalSince1970), for: CredentialStore.Keys.waterControlApiTokenSavedAt)
    }

    private func tokenSavedAt() -> Date? {
        guard let raw = store.get(CredentialStore.Keys.waterControlApiTokenSavedAt),
              let seconds = Double(raw) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private func authParams() throws -> WaterControlAuthParams {
        guard let account = store.get(CredentialStore.Keys.waterControlAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let aesKey = store.get(CredentialStore.Keys.waterControlAesKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let password = store.get(CredentialStore.Keys.waterControlPassword)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !account.isEmpty, !aesKey.isEmpty, !password.isEmpty else {
            throw AuthError.notLoggedIn("未找到水控登录参数")
        }
        return WaterControlAuthParams(account: account, aesKey: aesKey, password: password)
    }

    private func perform<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        let request = try makeRequest(path: path, queryItems: queryItems)
        logRequest(path: path, queryItems: queryItems, request: request)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        if let http = response as? HTTPURLResponse {
            mergeCookies(from: http)
            log(path: path, http: http, data: data)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.stripLeadingSlash), resolvingAgainstBaseURL: false) else {
            throw AuthError.loginFlowFailed("水控 URL 构造失败")
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw AuthError.loginFlowFailed("水控 URL 构造失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(TongjiHTTPClient.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        if let cookie = waterCookieHeader(), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AuthError.expired("水控登录态已失效")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.loginFlowFailed("水控 HTTP \(http.statusCode)")
        }
    }

    private func validate(retNo: Int, message: String?, operation: String) throws {
        guard retNo == 0 else {
            let msg = message?.nilIfEmpty ?? "\(operation)失败"
            if Self.requiresLogin(message: msg) {
                throw AuthError.expired("水控登录态已失效")
            }
            if Self.isReservationRestricted(message: msg) {
                throw AuthError.loginFlowFailed("该分组暂不可读：水控系统返回“\(msg)”。不会影响其他宿舍，可稍后只重试此宿舍。")
            }
            throw AuthError.loginFlowFailed(msg)
        }
    }

    private func waterCookieHeader() -> String? {
        let explicitCookie = store.get(CredentialStore.Keys.waterControlCookies)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fromJar = CookieJar.shared.loadHeader(for: baseURL)
        let merged = Self.mergeCookieHeaders([explicitCookie, fromJar])
        return merged.isEmpty ? nil : merged
    }

    private func mergeCookies(from response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            fields[key] = "\(value)"
        }
        guard fields.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame }) else {
            return
        }
        CookieJar.shared.mergeSetCookieFields(fields, for: url)
        let header = CookieJar.shared.loadHeader(for: baseURL)
        if !header.isEmpty {
            store.set(header, for: CredentialStore.Keys.waterControlCookies)
        }
    }

    private func log(path: String, http: HTTPURLResponse, data: Data) {
        let status = (try? JSONDecoder().decode(WaterBusinessStatus.self, from: data))
        let metrics = Self.responseMetrics(data: data)
        logger.debug("[Water] \(path, privacy: .public) HTTP \(http.statusCode) ret=\(status?.retNo.map(String.init) ?? "nil", privacy: .public) msg=\(Self.redacted(status?.retDsp), privacy: .public) listCount=\(metrics.listCount.map(String.init) ?? "nil", privacy: .public) tokenLen=\(metrics.tokenLength.map(String.init) ?? "nil", privacy: .public)")
    }

    private func logRequest(path: String, queryItems: [URLQueryItem], request: URLRequest) {
        let queryKeys = queryItems.map(\.name).joined(separator: ",")
        let cookieLength = request.value(forHTTPHeaderField: "Cookie")?.count ?? 0
        logger.debug("[Water] GET \(path, privacy: .public) queryKeys=\(queryKeys.isEmpty ? "<none>" : queryKeys, privacy: .public) cookie=\(cookieLength > 0, privacy: .public) cookieLen=\(cookieLength, privacy: .public)")
    }

    private static func requiresLogin(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("未登录") ||
            lower.contains("未登陆") ||
            lower.contains("登录") ||
            lower.contains("token") ||
            lower.contains("unauthorized")
    }

    private static func isReservationRestricted(message: String) -> Bool {
        message.contains("爽约") || message.contains("禁止预约")
    }

    private static func redacted(_ value: String?) -> String {
        let message = value ?? ""
        if message.isEmpty { return "<empty>" }
        return message.count > 80 ? String(message.prefix(80)) + "..." : message
    }

    private static func responseMetrics(data: Data) -> (listCount: Int?, tokenLength: Int?) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return (nil, nil)
        }
        let listCount = (dict["List"] as? [Any])?.count
        let tokenLength = (dict["Token"] as? String)?.count
        return (listCount, tokenLength)
    }

    private static func mergeCookieHeaders(_ headers: [String?]) -> String {
        var orderedNames: [String] = []
        var values: [String: String] = [:]
        for header in headers {
            for pair in (header ?? "").split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if values[name] == nil {
                    orderedNames.append(name)
                }
                values[name] = value
            }
        }
        return orderedNames.compactMap { name in
            guard let value = values[name] else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }
}

private struct WaterBusinessStatus: Decodable {
    let retNo: Int?
    let retDsp: String?

    enum CodingKeys: String, CodingKey {
        case retNo = "RetNo"
        case retDsp = "RetDsp"
    }
}

private struct WaterGroupResponse: Decodable {
    let retNo: Int
    let retDsp: String?
    let list: [WaterRemoteItem]

    enum CodingKeys: String, CodingKey {
        case retNo = "RetNo"
        case retDsp = "RetDsp"
        case list = "List"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retNo = try c.decodeLossyInt(forKey: .retNo) ?? -1
        retDsp = try c.decodeIfPresent(String.self, forKey: .retDsp)
        list = (try? c.decode([WaterRemoteItem].self, forKey: .list)) ?? []
    }
}

private struct WaterControllerResponse: Decodable {
    let retNo: Int
    let retDsp: String?
    let list: [WaterRemoteItem]

    enum CodingKeys: String, CodingKey {
        case retNo = "RetNo"
        case retDsp = "RetDsp"
        case list = "List"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retNo = try c.decodeLossyInt(forKey: .retNo) ?? -1
        retDsp = try c.decodeIfPresent(String.self, forKey: .retDsp)
        list = (try? c.decode([WaterRemoteItem].self, forKey: .list)) ?? []
    }
}

private struct WaterTokenResponse: Decodable {
    let retNo: Int
    let retDsp: String?
    let token: String?

    enum CodingKeys: String, CodingKey {
        case retNo = "RetNo"
        case retDsp = "RetDsp"
        case token = "Token"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retNo = try c.decodeLossyInt(forKey: .retNo) ?? -1
        retDsp = try c.decodeIfPresent(String.self, forKey: .retDsp)
        token = try c.decodeIfPresent(String.self, forKey: .token)
    }
}

private struct ControllerRequestVariant {
    let name: String
    let queryItems: [URLQueryItem]
}

private struct WaterRemoteItem: Decodable {
    let classNo: String
    let className: String
    let posNum: Int?
    let warnPosNum: Int?
    let useFreeRate: String?
    let bookRate: String?
    let actkind: String?
    let bookCode: String?

    enum CodingKeys: String, CodingKey {
        case classNo = "ClassNo"
        case className = "ClassName"
        case posNum = "PosNum"
        case warnPosNum = "WarnPosNum"
        case useFreeRate = "UseFreeRate"
        case bookRate = "BookRate"
        case actkind = "Actkind"
        case bookCode = "BookCode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classNo = try c.decodeLossyString(forKey: .classNo) ?? UUID().uuidString
        className = try c.decodeLossyString(forKey: .className) ?? "未知分组"
        posNum = try c.decodeLossyInt(forKey: .posNum)
        warnPosNum = try c.decodeLossyInt(forKey: .warnPosNum)
        useFreeRate = try c.decodeLossyString(forKey: .useFreeRate)
        bookRate = try c.decodeLossyString(forKey: .bookRate)
        actkind = try c.decodeLossyString(forKey: .actkind)
        bookCode = try c.decodeLossyString(forKey: .bookCode)
    }

    func asGroup() -> WaterControlGroup {
        WaterControlGroup(
            id: classNo,
            name: className,
            posNum: posNum,
            warnPosNum: warnPosNum,
            useFreeRate: useFreeRate,
            bookRate: bookRate,
            actkind: actkind,
            bookCode: bookCode
        )
    }

    func asDevice(group: WaterControlGroup) -> WaterControlDevice {
        WaterControlDevice(
            id: classNo,
            groupId: group.id,
            groupName: group.name,
            name: className,
            posNum: posNum,
            warnPosNum: warnPosNum,
            useFreeRate: useFreeRate,
            bookRate: bookRate,
            actkind: actkind,
            bookCode: bookCode
        )
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func decodeLossyInt(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

private extension String {
    var stripLeadingSlash: String {
        hasPrefix("/") ? String(dropFirst()) : self
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
