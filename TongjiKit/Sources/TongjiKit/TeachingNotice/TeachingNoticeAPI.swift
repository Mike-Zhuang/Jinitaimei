import Foundation

/// 教学管理信息系统通知公告 API。
///
/// 列表接口只返回摘要，正文可能很大且包含内嵌图片，因此详情按需请求。
public final class TeachingNoticeAPI {

    private let store: CredentialStore
    private let httpClient: TongjiHTTPClient

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.httpClient = TongjiHTTPClient(store: store, session: session)
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

    public func downloadAttachment(_ attachment: TeachingNoticeAttachment) async throws -> URL {
        try await withAuthRetry { [self] in
            try await downloadAttachmentOnce(attachment)
        }
    }

    /// 返回该附件已下载到本地的缓存文件 URL（若存在）。
    ///
    /// 用于详情页重新进入时恢复「已下载」状态，避免重复下载。
    /// 缓存落在 `temporaryDirectory`，与 `downloadAttachmentOnce` 的落盘路径一致。
    public func cachedAttachmentURL(for attachment: TeachingNoticeAttachment) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeFileName(attachment.fileName), isDirectory: false)
        return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
    }

    // MARK: - Once 版本

    public func fetchNoticesOnce(page: Int, pageSize: Int) async throws -> TeachingNoticePage {
        let body = try JSONEncoder().encode(
            TeachingNoticeListRequest(total: 0, pageNum: page, pageSize: pageSize)
        )
        let request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/commonservice/commonMsgPublish/findMyCommonMsgPublish",
            method: "POST",
            body: body
        )
        let data = try await httpClient.data(for: request, endpoint: .oneSystem)

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
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/commonservice/commonMsgPublish/findCommonMsgPublishById",
            queryItems: [
                URLQueryItem(name: "id", value: "\(id)"),
                URLQueryItem(name: "_t", value: "\(timestamp)")
            ]
        )
        let data = try await httpClient.data(for: request, endpoint: .oneSystem)
        print("[TeachingNotice] 详情响应 id=\(id) bytes=\(data.count)")

        let payload = try JSONDecoder().decode(TeachingNoticeDetailResponse.self, from: data)
        guard payload.code == 200, let item = payload.data else {
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "通知公告详情响应异常" : payload.msg)
        }

        let attachments = item.commonAttachmentList?.map {
            TeachingNoticeAttachment(
                id: $0.id,
                relationId: $0.relationId,
                fileName: $0.fileName,
                fileLocation: $0.fileLacation
            )
        } ?? []

        return TeachingNoticeDetail(
            id: item.id,
            title: item.title,
            contentHTML: item.content ?? "",
            publishTimeText: item.publishTime ?? "",
            createUser: item.createUser,
            attachments: attachments
        )
    }

    public func downloadAttachmentOnce(_ attachment: TeachingNoticeAttachment) async throws -> URL {
        let objectKey = try encryptedObjectKey(for: attachment.fileLocation)
        var request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/commonservice/obsfile/downloadfile?objectkey=\(objectKey)"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Content-Type")

        let (temporaryURL, response) = try await httpClient.download(for: request, endpoint: .oneSystem)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.loginFlowFailed("附件下载响应异常")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let fileSize = fileSize(at: temporaryURL)
        print(
            "[TeachingNotice] 附件下载响应 id=\(attachment.id) file=\(attachment.fileName) status=\(http.statusCode) type=\(contentType) bytes=\(fileSize)"
        )
        guard (200..<300).contains(http.statusCode),
              !contentType.localizedCaseInsensitiveContains("application/json"),
              !contentType.localizedCaseInsensitiveContains("text/html"),
              fileSize > 0 else {
            throw AuthError.loginFlowFailed("附件下载失败，请重试")
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeFileName(attachment.fileName), isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func encryptedObjectKey(for fileLocation: String) throws -> String {
        guard let aesKey = store.get(CredentialStore.Keys.tongjiAesKey),
              let aesIv = store.get(CredentialStore.Keys.tongjiAesIv),
              !aesKey.isEmpty,
              !aesIv.isEmpty else {
            throw AuthError.notLoggedIn("缺少一系统加密凭证，请重新登录校园账户")
        }
        let encrypted = try StudentCodeCipher.encryptOneSystemText(fileLocation, aesKey: aesKey, aesIv: aesIv)
        return StudentCodeCipher.encodeURIComponent(encrypted)
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }

    private func safeFileName(_ fileName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = fileName.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "attachment" : cleaned
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
    let commonAttachmentList: [TeachingNoticeAttachmentItem]?
}

private struct TeachingNoticeAttachmentItem: Decodable {
    let id: Int
    let relationId: Int
    let fileName: String
    let fileLacation: String
}

private struct TeachingNoticeDetailResponse: Decodable {
    let code: Int
    let msg: String
    let data: TeachingNoticeItem?
}
