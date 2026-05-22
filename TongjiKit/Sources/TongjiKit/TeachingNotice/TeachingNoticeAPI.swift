import Foundation

/// 教学管理信息系统通知公告 API。
///
/// 列表接口只返回摘要，正文可能很大且包含内嵌图片，因此详情按需请求。
public final class TeachingNoticeAPI {

    private let apiHost = "https://1.tongji.edu.cn"
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func fetchNotices(page: Int = 1, pageSize: Int = 10) async throws -> TeachingNoticePage {
        try await withAuthRetry { [self] in
            try await fetchNoticesOnce(page: page, pageSize: pageSize)
        }
    }

    public func fetchLatestNotice() async throws -> TeachingNotice? {
        try await withAuthRetry { [self] in
            try await fetchLatestNoticeOnce()
        }
    }

    public func fetchNoticeDetail(id: Int) async throws -> TeachingNoticeDetail {
        try await withAuthRetry { [self] in
            try await fetchNoticeDetailOnce(id: id)
        }
    }

    // MARK: - Once 版本

    public func fetchNoticesOnce(page: Int, pageSize: Int) async throws -> TeachingNoticePage {
        guard let cookie = currentCookieHeader(), !cookie.isEmpty else {
            throw AuthError.notLoggedIn("未找到登录凭证，请先在设置中登录校园账户")
        }
        let sessionId = store.get(CredentialStore.Keys.tongjiSessionId) ?? ""
        let url = URL(string: "\(apiHost)/api/commonservice/commonMsgPublish/findMyCommonMsgPublish")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            TeachingNoticeListRequest(total: 0, pageNum: page, pageSize: pageSize)
        )
        applyAuthHeaders(&request, cookie: cookie, sessionId: sessionId)

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response, url: url)

        let payload = try JSONDecoder().decode(TeachingNoticeListResponse.self, from: data)
        guard payload.code == 200, let data = payload.data else {
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "通知公告列表响应异常" : payload.msg)
        }

        let notices = data.list.map {
            TeachingNotice(
                id: $0.id,
                title: $0.title,
                publishTimeText: $0.publishTime ?? "",
                topStatus: $0.topStatus ?? "0",
                read: $0.marReadStatus ?? false
            )
        }
        return TeachingNoticePage(
            notices: TeachingNotice.sortedForList(notices),
            page: data.pageNum,
            pageSize: data.pageSize,
            total: data.total
        )
    }

    public func fetchLatestNoticeOnce() async throws -> TeachingNotice? {
        var all: [TeachingNotice] = []
        var currentPage = 1
        while true {
            let page = try await fetchNoticesOnce(page: currentPage, pageSize: 10)
            all.append(contentsOf: page.notices)
            guard page.hasMore else { break }
            currentPage += 1
        }
        return TeachingNotice.newest(all)
    }

    public func fetchNoticeDetailOnce(id: Int) async throws -> TeachingNoticeDetail {
        guard let cookie = currentCookieHeader(), !cookie.isEmpty else {
            throw AuthError.notLoggedIn("未找到登录凭证，请先在设置中登录校园账户")
        }
        let sessionId = store.get(CredentialStore.Keys.tongjiSessionId) ?? ""
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string:
            "\(apiHost)/api/commonservice/commonMsgPublish/findCommonMsgPublishById?id=\(id)&_t=\(timestamp)"
        )!
        var request = URLRequest(url: url)
        applyAuthHeaders(&request, cookie: cookie, sessionId: sessionId)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            print("[TeachingNotice] 详情响应 id=\(id) status=\(http.statusCode) bytes=\(data.count)")
        }
        try ensureAuth(response: response, url: url)

        let payload = try JSONDecoder().decode(TeachingNoticeDetailResponse.self, from: data)
        guard payload.code == 200, let item = payload.data else {
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "通知公告详情响应异常" : payload.msg)
        }

        return TeachingNoticeDetail(
            id: item.id,
            title: item.title,
            contentHTML: item.content ?? "",
            publishTimeText: item.publishTime ?? "",
            createUser: item.createUser
        )
    }

    private func currentCookieHeader() -> String? {
        let host = URL(string: apiHost)!
        let fromJar = CookieJar.shared.loadHeader(for: host)
        if !fromJar.isEmpty { return fromJar }
        return store.get(CredentialStore.Keys.tongjiCookies)
    }

    private func applyAuthHeaders(_ request: inout URLRequest, cookie: String, sessionId: String) {
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
    }

    /// 401/403 仅抛 `AuthError.expired`；不 remove。
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
}

public struct TeachingNoticePage: Equatable {
    public let notices: [TeachingNotice]
    public let page: Int
    public let pageSize: Int
    public let total: Int

    public var hasMore: Bool {
        page * pageSize < total
    }
}

private struct TeachingNoticeListRequest: Encodable {
    let total: Int
    let pageNum: Int
    let pageSize: Int

    enum CodingKeys: String, CodingKey {
        case total
        case pageNum = "pageNum_"
        case pageSize = "pageSize_"
    }
}

private struct TeachingNoticeListResponse: Decodable {
    let code: Int
    let msg: String
    let data: TeachingNoticeListData?
}

private struct TeachingNoticeListData: Decodable {
    let pageNum: Int
    let pageSize: Int
    let total: Int
    let list: [TeachingNoticeItem]

    enum CodingKeys: String, CodingKey {
        case pageNum = "pageNum_"
        case pageSize = "pageSize_"
        case total = "total_"
        case list
    }
}

private struct TeachingNoticeItem: Decodable {
    let id: Int
    let title: String
    let publishTime: String?
    let topStatus: String?
    let marReadStatus: Bool?
    let createUser: String?
    let content: String?
}

private struct TeachingNoticeDetailResponse: Decodable {
    let code: Int
    let msg: String
    let data: TeachingNoticeItem?
}
