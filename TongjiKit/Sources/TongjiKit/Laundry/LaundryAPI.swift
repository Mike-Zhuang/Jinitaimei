import Foundation
import os.log

public final class LaundryAPI: @unchecked Sendable {
    private let baseURL = URL(string: "https://wx2.cooleasy.net")!
    private let session: URLSession
    private let store: CredentialStore
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "LaundryAPI")
    private let defaultLongitude = "121.498886"
    private let defaultLatitude = "31.28323"

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func clearSession() {
        store.remove(CredentialStore.Keys.laundryCookies)
        logger.debug("[Laundry] 已清空洗衣机会话 Cookie")
    }

    public func fetchRooms() async throws -> [LaundryRoom] {
        let token = try await fetchToken(
            path: "/Home/lineUpNearbyEquipment",
            queryItems: [
                URLQueryItem(name: "typeId", value: "1"),
                URLQueryItem(name: "r", value: Self.timestampSeed())
            ],
            operation: "洗衣房列表"
        )
        let response: LaundryRoomListResponse = try await postForm(
            path: "/Home/ApiWashingRoomList",
            refererPath: "/Home/lineUpNearbyEquipment?typeId=1",
            fields: [
                "__RequestVerificationToken": token,
                "TypeId": "1",
                "LonX": defaultLongitude,
                "LatY": defaultLatitude
            ],
            operation: "洗衣房列表"
        )
        try validate(success: response.success, message: response.message, operation: "获取洗衣房列表")
        logger.debug("[Laundry] 洗衣房列表获取成功 count=\(response.data.count, privacy: .public)")
        return response.data.map { $0.asRoom() }
    }

    public func fetchMachines(for room: LaundryRoom, status: LaundryMachineQueryStatus = .all) async throws -> [LaundryMachine] {
        logger.debug("[Laundry] 开始获取洗衣机 roomIdLen=\(room.id.count, privacy: .public) room=\(room.displayName, privacy: .public) status=\(status.rawValue, privacy: .public)")
        let token = try await fetchToken(
            path: "/Home/NearbyEquipment",
            queryItems: [
                URLQueryItem(name: "typeId", value: "1"),
                URLQueryItem(name: "address", value: room.rawAddress)
            ],
            operation: "洗衣机列表"
        )
        let response: LaundryMachineListResponse = try await postForm(
            path: "/Home/ApiMachineListByAddress",
            refererPath: "/Home/NearbyEquipment?typeId=1",
            fields: [
                "__RequestVerificationToken": token,
                "TypeId": "1",
                "Address": room.rawAddress,
                "status": status.rawValue
            ],
            operation: "洗衣机列表"
        )
        try validate(success: response.success, message: response.message, operation: "获取洗衣机列表")
        logger.debug("[Laundry] 洗衣机列表获取成功 room=\(room.displayName, privacy: .public) count=\(response.data.count, privacy: .public)")
        return response.data.map { $0.asMachine(room: room) }
    }

    private func fetchToken(
        path: String,
        queryItems: [URLQueryItem],
        operation: String
    ) async throws -> String {
        let request = try makeGetRequest(path: path, queryItems: queryItems)
        logger.debug("[Laundry] GET \(path, privacy: .public) operation=\(operation, privacy: .public) queryKeys=\(queryItems.map(\.name).joined(separator: ","), privacy: .public) cookie=\(self.hasStoredCookie, privacy: .public) cookieNames=\(self.storedCookieNamesDescription, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        persistCookies(from: response, operation: operation)
        do {
            try validateHTTP(response, operation: operation)
        } catch let error as LaundryError {
            if case .network = error, isLikelyMissingCoolEasySession(response) {
                let hadLoginStatus = storedCookieNames.contains("loginStatusId")
                if hadLoginStatus {
                    clearSession()
                    throw LaundryError.sessionRequired("洗衣机会话已失效，请重新初始化洗衣机会话后重试")
                } else {
                    throw LaundryError.sessionRequired("洗衣机服务需要 CoolEasy 微信会话（缺少 loginStatusId），当前无法直接初始化")
                }
            }
            throw error
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
            throw LaundryError.protocolError("\(operation)页面无法解码")
        }
        guard let token = Self.extractRequestVerificationToken(from: html) else {
            logger.debug("[Laundry] \(operation, privacy: .public) 页面未找到 anti-forgery token htmlLen=\(html.count, privacy: .public) cookieNames=\(self.storedCookieNamesDescription, privacy: .public)")
            throw LaundryError.protocolError("\(operation)页面缺少请求校验参数")
        }
        logger.debug("[Laundry] \(operation, privacy: .public) 页面 token 已提取 tokenLen=\(token.count, privacy: .public)")
        return token
    }

    private func postForm<T: Decodable>(
        path: String,
        refererPath: String,
        fields: [String: String],
        operation: String
    ) async throws -> T {
        let request = try makePostRequest(path: path, refererPath: refererPath, fields: fields)
        logger.debug("[Laundry] POST \(path, privacy: .public) operation=\(operation, privacy: .public) formKeys=\(fields.keys.sorted().joined(separator: ","), privacy: .public) cookie=\(self.hasStoredCookie, privacy: .public) cookieNames=\(self.storedCookieNamesDescription, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        persistCookies(from: response, operation: operation)
        try validateHTTP(response, operation: operation)
        logBusinessStatus(path: path, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeGetRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.stripLeadingSlash), resolvingAgainstBaseURL: false) else {
            throw LaundryError.protocolError("洗衣机 URL 构造失败")
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw LaundryError.protocolError("洗衣机 URL 构造失败")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, refererPath: path)
        request.setValue(Self.weChatUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("com.tencent.mm", forHTTPHeaderField: "X-Requested-With")
        return request
    }

    private func makePostRequest(path: String, refererPath: String, fields: [String: String]) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path.stripLeadingSlash)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.formEncoded(fields).data(using: .utf8)
        applyCommonHeaders(to: &request, refererPath: refererPath)
        request.setValue(Self.weChatUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        return request
    }

    private func applyCommonHeaders(to request: inout URLRequest, refererPath: String) {
        request.timeoutInterval = 20
        request.setValue(TongjiHTTPClient.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(refererURLString(path: refererPath), forHTTPHeaderField: "Referer")
        if let cookie = currentCookieHeader(), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    private func refererURLString(path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        if path.hasPrefix("/") {
            return baseURL.absoluteString + path
        }
        return baseURL.absoluteString + "/" + path
    }

    private func validateHTTP(_ response: URLResponse, operation: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            logger.debug("[Laundry] \(operation, privacy: .public) HTTP \(http.statusCode, privacy: .public) cookieNames=\(self.storedCookieNamesDescription, privacy: .public)")
            throw LaundryError.network("洗衣机服务 HTTP \(http.statusCode)")
        }
    }

    private func validate(success: Int, message: String?, operation: String) throws {
        guard success == 1 else {
            throw LaundryError.protocolError(message?.nilIfEmpty ?? "\(operation)失败")
        }
    }

    private func logBusinessStatus(path: String, data: Data) {
        guard let status = try? JSONDecoder().decode(LaundryBusinessStatus.self, from: data) else {
            logger.debug("[Laundry] \(path, privacy: .public) 业务响应无法解析 status")
            return
        }
        logger.debug("[Laundry] \(path, privacy: .public) success=\(status.success, privacy: .public) msg=\(Self.redacted(status.message), privacy: .public) count=\(status.dataCount.map(String.init) ?? "nil", privacy: .public)")
    }

    private var hasStoredCookie: Bool {
        currentCookieHeader()?.isEmpty == false
    }

    private var storedCookieNames: [String] {
        cookieNames(from: currentCookieHeader())
    }

    private var storedCookieNamesDescription: String {
        let names = storedCookieNames
        return names.isEmpty ? "<empty>" : names.joined(separator: ",")
    }

    private func currentCookieHeader() -> String? {
        store.get(CredentialStore.Keys.laundryCookies)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func persistCookies(from response: URLResponse, operation: String) {
        guard let http = response as? HTTPURLResponse else { return }
        let setCookies = http.allHeaderFields.compactMap { key, value -> String? in
            guard String(describing: key).caseInsensitiveCompare("Set-Cookie") == .orderedSame else { return nil }
            return String(describing: value)
        }
        guard !setCookies.isEmpty else { return }
        let merged = mergeCookies(existingHeader: currentCookieHeader(), setCookieHeaders: setCookies)
        guard !merged.isEmpty else { return }
        store.set(merged, for: CredentialStore.Keys.laundryCookies)
        logger.debug("[Laundry] \(operation, privacy: .public) 已回写 Cookie names=\(self.cookieNames(from: merged).joined(separator: ","), privacy: .public)")
    }

    private func mergeCookies(existingHeader: String?, setCookieHeaders: [String]) -> String {
        var pairs: [String: String] = [:]
        for part in (existingHeader ?? "").split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equal = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<equal])
            let value = String(trimmed[trimmed.index(after: equal)...])
            guard !name.isEmpty else { continue }
            pairs[name] = value
        }

        for header in setCookieHeaders {
            // 一些代理会把多个 Set-Cookie 折叠成逗号分隔。只按 cookie 起始段取 name=value，
            // 避免把 Expires 里的逗号误拆成新 cookie。
            let candidates = header.components(separatedBy: ", ")
            for candidate in candidates {
                guard let first = candidate.split(separator: ";", maxSplits: 1).first else { continue }
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let equal = trimmed.firstIndex(of: "=") else { continue }
                let name = String(trimmed[..<equal])
                let value = String(trimmed[trimmed.index(after: equal)...])
                guard !name.isEmpty else { continue }
                pairs[name] = value
            }
        }

        return pairs
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func cookieNames(from header: String?) -> [String] {
        (header ?? "")
            .split(separator: ";")
            .compactMap { part in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let equal = trimmed.firstIndex(of: "=") else { return nil }
                return String(trimmed[..<equal])
            }
            .sorted()
    }

    private func isLikelyMissingCoolEasySession(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 500
    }

    static func extractRequestVerificationToken(from html: String) -> String? {
        let patterns = [
            #"<input[^>]*name=["']__RequestVerificationToken["'][^>]*value=["']([^"']+)["'][^>]*>"#,
            #"<input[^>]*value=["']([^"']+)["'][^>]*name=["']__RequestVerificationToken["'][^>]*>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            return String(html[tokenRange])
        }
        return nil
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func timestampSeed() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        return formatter.string(from: Date())
    }

    private static let weChatUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.60 NetType/WIFI Language/zh_CN"

    private static func redacted(_ value: String?) -> String {
        let message = value ?? ""
        if message.isEmpty { return "<empty>" }
        return message.count > 80 ? String(message.prefix(80)) + "..." : message
    }
}

public enum LaundryMachineQueryStatus: String, Sendable {
    case all
    case free
}

public enum LaundryError: LocalizedError, Sendable {
    case network(String)
    case protocolError(String)
    case sessionRequired(String)

    public var errorDescription: String? {
        switch self {
        case .network(let message), .protocolError(let message), .sessionRequired(let message):
            message
        }
    }
}

private struct LaundryBusinessStatus: Decodable {
    let success: Int
    let message: String?
    let dataCount: Int?

    enum CodingKeys: String, CodingKey {
        case success
        case message = "msg"
        case data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decodeLossyInt(forKey: .success) ?? 0
        message = try c.decodeLossyString(forKey: .message)
        dataCount = (try? c.decode([AnyDecodable].self, forKey: .data))?.count
    }
}

private struct LaundryRoomListResponse: Decodable {
    let success: Int
    let message: String?
    let data: [LaundryRemoteRoom]

    enum CodingKeys: String, CodingKey {
        case success
        case message = "msg"
        case data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decodeLossyInt(forKey: .success) ?? 0
        message = try c.decodeLossyString(forKey: .message)
        data = (try? c.decode([LaundryRemoteRoom].self, forKey: .data)) ?? []
    }
}

private struct LaundryMachineListResponse: Decodable {
    let success: Int
    let message: String?
    let data: [LaundryRemoteMachine]

    enum CodingKeys: String, CodingKey {
        case success
        case message = "msg"
        case data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decodeLossyInt(forKey: .success) ?? 0
        message = try c.decodeLossyString(forKey: .message)
        data = (try? c.decode([LaundryRemoteMachine].self, forKey: .data)) ?? []
    }
}

private struct LaundryRemoteRoom: Decodable {
    let roomName: String
    let address: String
    let washingMachineCount: Int
    let dryerCount: Int
    let distance: Int?
    let distanceMessage: String?

    enum CodingKeys: String, CodingKey {
        case roomName = "RoomName"
        case address = "Address"
        case washingMachineCount = "WashingMachineCount"
        case dryerCount = "DryerCount"
        case distance = "Distance"
        case distanceMessage = "DistanceMsg"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomName = try c.decodeLossyString(forKey: .roomName) ?? "未知洗衣房"
        address = try c.decodeLossyString(forKey: .address) ?? roomName
        washingMachineCount = try c.decodeLossyInt(forKey: .washingMachineCount) ?? 0
        dryerCount = try c.decodeLossyInt(forKey: .dryerCount) ?? 0
        distance = try c.decodeLossyInt(forKey: .distance)
        distanceMessage = try c.decodeLossyString(forKey: .distanceMessage)
    }

    func asRoom() -> LaundryRoom {
        LaundryRoom(
            id: address,
            rawName: roomName,
            rawAddress: address,
            washingMachineCount: washingMachineCount,
            dryerCount: dryerCount,
            distance: distance,
            distanceMessage: distanceMessage
        )
    }
}

private struct LaundryRemoteMachine: Decodable {
    let isOnline: Bool?
    let runningStatus: Int?
    let runningProgram: Int?
    let runningStatusDescription: String?
    let appointmentStatus: Bool?
    let remainingMinutes: Int?
    let machineSn: String
    let isOnlineMachine: Bool?
    let machineTypeName: String

    enum CodingKeys: String, CodingKey {
        case isOnline = "IsOnline"
        case runningStatus = "RunningStatus"
        case runningProgram = "RunningProgram"
        case runningStatusDescription = "RunningStatusDescription"
        case appointmentStatus = "AppointmentStatus"
        case remainingMinutes = "RemainingTimeL"
        case machineSn = "MachineSn"
        case isOnlineMachine = "IsOnlineMachine"
        case machineTypeName = "MachineTypeName"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOnline = try c.decodeLossyBool(forKey: .isOnline)
        runningStatus = try c.decodeLossyInt(forKey: .runningStatus)
        runningProgram = try c.decodeLossyInt(forKey: .runningProgram)
        runningStatusDescription = try c.decodeLossyString(forKey: .runningStatusDescription)
        appointmentStatus = try c.decodeLossyBool(forKey: .appointmentStatus)
        remainingMinutes = try c.decodeLossyInt(forKey: .remainingMinutes)
        machineSn = try c.decodeLossyString(forKey: .machineSn) ?? UUID().uuidString
        isOnlineMachine = try c.decodeLossyBool(forKey: .isOnlineMachine)
        machineTypeName = try c.decodeLossyString(forKey: .machineTypeName) ?? "洗衣机"
    }

    func asMachine(room: LaundryRoom) -> LaundryMachine {
        LaundryMachine(
            id: "\(room.id)#\(machineSn)",
            roomId: room.id,
            roomName: room.displayName,
            machineSn: machineSn,
            machineTypeName: machineTypeName,
            isOnline: isOnline,
            runningStatus: runningStatus,
            runningProgram: runningProgram,
            runningStatusDescription: runningStatusDescription,
            appointmentStatus: appointmentStatus,
            remainingMinutes: remainingMinutes,
            isOnlineMachine: isOnlineMachine
        )
    }
}

private struct AnyDecodable: Decodable {}

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

    func decodeLossyBool(forKey key: Key) throws -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes"].contains(normalized) { return true }
            if ["false", "0", "no"].contains(normalized) { return false }
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
