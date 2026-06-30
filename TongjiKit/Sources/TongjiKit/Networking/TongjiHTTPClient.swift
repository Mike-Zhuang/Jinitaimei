import Foundation
import os.log

/// 校园系统网络底座。
///
/// 只负责稳定、可复用的请求构造和鉴权错误映射；各业务 API 仍保留自己的协议解析。
/// 不输出 Cookie / Token / sessiondata 原文，日志只保留路径、状态码与脱敏后的业务消息。
public final class TongjiHTTPClient: @unchecked Sendable {

    public enum EndpointKind: Sendable {
        case oneSystem
        case star
        case yikatong
        case librarySpace

        var baseURL: URL {
            switch self {
            case .oneSystem:
                URL(string: "https://1.tongji.edu.cn")!
            case .star:
                URL(string: "https://star.tongji.edu.cn")!
            case .yikatong:
                URL(string: "https://pay-yikatong.tongji.edu.cn")!
            case .librarySpace:
                URL(string: "https://space.tongji.edu.cn")!
            }
        }
    }

    public enum OneSystemAuthContext: Int, Sendable {
        case examSchedule = 9102
        case gradeReport = 12174
    }

    public static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let store: CredentialStore
    private let session: URLSession
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "TongjiHTTPClient")

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func request(
        endpoint: EndpointKind,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) throws -> URLRequest {
        let url = try makeURL(endpoint: endpoint, path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        applyCommonHeaders(to: &request, endpoint: endpoint)
        try applyAuthHeaders(to: &request, endpoint: endpoint)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    public func data(for request: URLRequest, endpoint: EndpointKind) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, endpoint: endpoint)
        return data
    }

    public func download(for request: URLRequest, endpoint: EndpointKind) async throws -> (URL, URLResponse) {
        let (url, response) = try await session.download(for: request)
        try validate(response: response, data: nil, endpoint: endpoint)
        return (url, response)
    }

    public func switchOneSystemAuthContext(_ context: OneSystemAuthContext) async throws {
        print("[OneSystemHTTP] 开始切换上下文 authId=\(context.rawValue)")
        let body = try JSONEncoder().encode(OneSystemAuthContextRequest(authId: context.rawValue))
        let request = try request(
            endpoint: .oneSystem,
            path: "/api/sessionservice/session/currentAuthId",
            method: "POST",
            body: body
        )
        let data = try await data(for: request, endpoint: .oneSystem)
        let payload = try JSONDecoder().decode(BusinessStatus.self, from: data)
        guard payload.code == 200 else {
            print("[OneSystemHTTP] 上下文切换失败 authId=\(context.rawValue) code=\(payload.code.map(String.init) ?? "nil") msg=\(Self.redacted(payload.msg))")
            throw AuthError.loginFlowFailed(payload.msg?.nilIfEmpty ?? "切换教务上下文失败")
        }
        print("[OneSystemHTTP] 上下文切换成功 authId=\(context.rawValue)")
    }

    private func makeURL(
        endpoint: EndpointKind,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let base = endpoint.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let raw = "\(base)/\(path.stripLeadingSlash)"
        guard var components = URLComponents(string: raw) else {
            throw AuthError.loginFlowFailed("URL 构造失败")
        }
        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }
        guard let url = components.url else {
            throw AuthError.loginFlowFailed("URL 构造失败")
        }
        return url
    }

    private func applyCommonHeaders(to request: inout URLRequest, endpoint: EndpointKind) {
        request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        switch endpoint {
        case .oneSystem:
            request.setValue(endpoint.baseURL.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("\(endpoint.baseURL.absoluteString)/workbench", forHTTPHeaderField: "Referer")
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        case .star:
            request.setValue("h5", forHTTPHeaderField: "Platform")
        case .yikatong:
            request.setValue("h5", forHTTPHeaderField: "synaccesssource")
        case .librarySpace:
            request.setValue(endpoint.baseURL.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("\(endpoint.baseURL.absoluteString)/h5/", forHTTPHeaderField: "Referer")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("zh", forHTTPHeaderField: "lang")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    private func applyAuthHeaders(to request: inout URLRequest, endpoint: EndpointKind) throws {
        switch endpoint {
        case .oneSystem:
            let cookieSnapshot = oneSystemCookieSnapshot()
            var sessionId = store.get(CredentialStore.Keys.tongjiSessionId)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !cookieSnapshot.header.isEmpty else {
                logOneSystemAuth(
                    request: request,
                    cookieSource: cookieSnapshot.source,
                    cookieLength: 0,
                    cookieNames: cookieSnapshot.names,
                    xTokenLength: sessionId.count,
                    reason: "missing-cookie"
                )
                throw AuthError.expired("未找到一系统 Cookie，尝试恢复登录")
            }
            if sessionId.isEmpty,
               let cookieSessionId = Self.cookieValue(named: "sessionid", in: cookieSnapshot.header),
               !cookieSessionId.isEmpty {
                sessionId = cookieSessionId
                store.set(cookieSessionId, for: CredentialStore.Keys.tongjiSessionId)
                print("[OneSystemHTTP] 已从 Cookie 回填 X-Token，len=\(cookieSessionId.count)")
            }
            guard !sessionId.isEmpty else {
                logOneSystemAuth(
                    request: request,
                    cookieSource: cookieSnapshot.source,
                    cookieLength: cookieSnapshot.header.count,
                    cookieNames: cookieSnapshot.names,
                    xTokenLength: 0,
                    reason: "missing-x-token"
                )
                throw AuthError.expired("缺少一系统 X-Token，尝试恢复登录")
            }
            request.setValue(cookieSnapshot.header, forHTTPHeaderField: "Cookie")
            request.setValue(sessionId, forHTTPHeaderField: "X-Token")
            logOneSystemAuth(
                request: request,
                cookieSource: cookieSnapshot.source,
                cookieLength: cookieSnapshot.header.count,
                cookieNames: cookieSnapshot.names,
                xTokenLength: sessionId.count,
                reason: "ready"
            )
        case .star:
            if let token = validStoredToken(CredentialStore.Keys.starBearerToken, minLength: 20) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .yikatong:
            guard let token = validStoredToken(CredentialStore.Keys.yikatongBearerToken, minLength: 10) else {
                throw AuthError.expired("未找到校园卡访问令牌")
            }
            request.setValue("bearer \(token)", forHTTPHeaderField: "synjones-auth")
            if let cookie = store.get(CredentialStore.Keys.yikatongCookies)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        case .librarySpace:
            guard let jwt = validStoredToken(CredentialStore.Keys.librarySpaceBearerToken, minLength: 20) else {
                throw AuthError.notLoggedIn("图书馆系统登录失效，请稍后重试")
            }
            request.setValue("bearer\(jwt)", forHTTPHeaderField: "authorization")
        }
    }

    private func oneSystemCookieSnapshot() -> OneSystemCookieSnapshot {
        let fromJar = CookieJar.shared.loadHeader(for: EndpointKind.oneSystem.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromJar.isEmpty {
            return OneSystemCookieSnapshot(
                header: fromJar,
                source: "CookieJar",
                names: Self.cookieNames(from: fromJar)
            )
        }
        let legacy = store.get(CredentialStore.Keys.tongjiCookies)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return OneSystemCookieSnapshot(
            header: legacy,
            source: legacy.isEmpty ? "none" : "Keychain",
            names: Self.cookieNames(from: legacy)
        )
    }

    private func validStoredToken(_ key: String, minLength: Int) -> String? {
        guard let token = store.get(key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= minLength,
              token.lowercased() != "bearer" else {
            return nil
        }
        return token
    }

    private func validate(response: URLResponse, data: Data?, endpoint: EndpointKind) throws {
        guard let http = response as? HTTPURLResponse else { return }
        mergeSetCookieFields(from: http, endpoint: endpoint)
        if endpoint == .oneSystem {
            logOneSystemResponse(http: http, data: data)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AuthError.expired("\(endpoint.logName) 凭证已失效")
        }
        if !(200..<300).contains(http.statusCode) {
            throw AuthError.loginFlowFailed("HTTP \(http.statusCode)")
        }
        if let data,
           let status = try? JSONDecoder().decode(BusinessStatus.self, from: data),
           Self.businessResponseRequiresLogin(status) {
            log(endpoint: endpoint, response: http, status: status)
            throw AuthError.expired("\(endpoint.logName) 凭证已失效")
        }
        if let data, let status = try? JSONDecoder().decode(BusinessStatus.self, from: data) {
            log(endpoint: endpoint, response: http, status: status)
        }
    }

    private func mergeSetCookieFields(from response: HTTPURLResponse, endpoint: EndpointKind) {
        guard endpoint == .oneSystem, let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            if let value = value as? String {
                fields[key] = value
            } else {
                fields[key] = "\(value)"
            }
        }
        guard fields.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame }) else {
            return
        }
        CookieJar.shared.mergeSetCookieFields(fields, for: url)
        let cookieNames = Self.setCookieNames(from: fields)
        print("[OneSystemHTTP] Set-Cookie 已回写 path=\(url.path) names=\(Self.joinedNames(cookieNames))")
    }

    private func log(endpoint: EndpointKind, response: HTTPURLResponse, status: BusinessStatus) {
        let path = response.url?.path ?? "<unknown>"
        let message = Self.redacted(status.msg)
        logger.debug("[\(endpoint.logName)] \(path, privacy: .public) HTTP \(response.statusCode) code=\(status.code.map(String.init) ?? "nil", privacy: .public) msg=\(message, privacy: .public)")
    }

    private static func businessResponseRequiresLogin(_ status: BusinessStatus) -> Bool {
        if status.code == 401 || status.code == 403 { return true }
        let message = (status.msg ?? "").lowercased()
        if message.isEmpty { return false }
        return message.contains("未登录") ||
               message.contains("未登陆") ||
               message.contains("尚未登录") ||
               message.contains("请登录") ||
               message.contains("登录失效") ||
               message.contains("unauthorized")
    }

    private static func redacted(_ value: String?) -> String {
        let message = value ?? ""
        if message.isEmpty { return "<empty>" }
        guard message.count > 80 else { return message }
        return String(message.prefix(80)) + "..."
    }

    private func logOneSystemAuth(
        request: URLRequest,
        cookieSource: String,
        cookieLength: Int,
        cookieNames: [String],
        xTokenLength: Int,
        reason: String
    ) {
        let url = request.url
        let path = url?.path ?? "<unknown>"
        let queryKeys = Self.queryKeys(from: url)
        let method = request.httpMethod ?? "GET"
        print(
            "[OneSystemHTTP] 鉴权 \(reason) \(method) \(path) queryKeys=\(Self.joinedNames(queryKeys)) cookieSource=\(cookieSource) cookieLen=\(cookieLength) cookieNames=\(Self.joinedNames(cookieNames)) xToken=\(xTokenLength > 0) xTokenLen=\(xTokenLength)"
        )
    }

    private func logOneSystemResponse(http: HTTPURLResponse, data: Data?) {
        let path = http.url?.path ?? "<unknown>"
        let status: BusinessStatus? = data.flatMap { try? JSONDecoder().decode(BusinessStatus.self, from: $0) }
        let code = status?.code.map(String.init) ?? "nil"
        let message = Self.redacted(status?.msg)
        let setCookieNames = Self.setCookieNames(from: http.allHeaderFields)
        print(
            "[OneSystemHTTP] 响应 \(path) HTTP \(http.statusCode) code=\(code) msg=\(message) bytes=\(data?.count ?? 0) setCookieNames=\(Self.joinedNames(setCookieNames))"
        )
    }

    private static func queryKeys(from url: URL?) -> [String] {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return []
        }
        return items.map(\.name).sorted()
    }

    private static func cookieNames(from header: String) -> [String] {
        header
            .split(separator: ";")
            .compactMap { segment -> String? in
                let pieces = segment.split(separator: "=", maxSplits: 1)
                guard let name = pieces.first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    return nil
                }
                return name
            }
            .sorted()
    }

    private static func cookieValue(named targetName: String, in header: String) -> String? {
        for segment in header.split(separator: ";") {
            let pieces = segment.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare(targetName) == .orderedSame else { continue }
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func setCookieNames(from fields: [AnyHashable: Any]) -> [String] {
        var names: [String] = []
        for (key, value) in fields {
            guard let key = key as? String,
                  key.caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                continue
            }
            let raw = "\(value)"
            names.append(contentsOf: raw
                .split(separator: ",")
                .compactMap { chunk -> String? in
                    let firstPair = chunk.split(separator: ";", maxSplits: 1).first ?? ""
                    let pieces = firstPair.split(separator: "=", maxSplits: 1)
                    guard let name = pieces.first?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !name.isEmpty else {
                        return nil
                    }
                    return name
                })
        }
        return names.sorted()
    }

    private static func setCookieNames(from fields: [String: String]) -> [String] {
        var normalized: [AnyHashable: Any] = [:]
        for (key, value) in fields {
            normalized[key] = value
        }
        return setCookieNames(from: normalized)
    }

    private static func joinedNames(_ values: [String]) -> String {
        values.isEmpty ? "<empty>" : values.joined(separator: ",")
    }
}

private struct OneSystemCookieSnapshot {
    let header: String
    let source: String
    let names: [String]
}

private struct OneSystemAuthContextRequest: Encodable {
    let authId: Int
}

private struct BusinessStatus: Decodable {
    let code: Int?
    let msg: String?

    enum CodingKeys: String, CodingKey {
        case code, msg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intCode = try? container.decode(Int.self, forKey: .code) {
            code = intCode
        } else if let stringCode = try? container.decode(String.self, forKey: .code) {
            code = Int(stringCode)
        } else {
            code = nil
        }
        msg = try? container.decode(String.self, forKey: .msg)
    }
}

private extension TongjiHTTPClient.EndpointKind {
    var logName: String {
        switch self {
        case .oneSystem:
            return "OneSystem"
        case .star:
            return "STAR"
        case .yikatong:
            return "Yikatong"
        case .librarySpace:
            return "LibrarySpace"
        }
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
