import Foundation

/// 教学管理信息系统通知公告摘要。
public struct TeachingNotice: Identifiable, Codable, Equatable, Hashable {
    public let id: Int
    public let title: String
    public let publishTimeText: String
    public let topStatus: String
    public let read: Bool

    public init(id: Int, title: String, publishTimeText: String, topStatus: String, read: Bool) {
        self.id = id
        self.title = title
        self.publishTimeText = publishTimeText
        self.topStatus = topStatus
        self.read = read
    }

    public var isPinned: Bool {
        topStatus == "1"
    }

    public var publishDate: Date {
        Self.parseDate(publishTimeText) ?? .distantPast
    }

    public var displayDate: String {
        guard publishDate > .distantPast else { return publishTimeText }
        return Self.displayFormatter.string(from: publishDate)
    }

    public static func sortedForList(_ notices: [TeachingNotice]) -> [TeachingNotice] {
        notices.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.publishDate > rhs.publishDate
        }
    }

    public static func newest(_ notices: [TeachingNotice]) -> TeachingNotice? {
        notices.max { $0.publishDate < $1.publishDate }
    }

    static func parseDate(_ text: String) -> Date? {
        for formatter in parseFormatters {
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    private static let parseFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss.S",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// 通知公告附件摘要。
public struct TeachingNoticeAttachment: Identifiable, Codable, Equatable, Hashable {
    public let id: Int
    public let relationId: Int
    public let fileName: String
    public let fileLocation: String

    public init(id: Int, relationId: Int, fileName: String, fileLocation: String) {
        self.id = id
        self.relationId = relationId
        self.fileName = fileName
        self.fileLocation = fileLocation
    }
}

/// 通知公告详情，只保留 App 展示需要的字段。
public struct TeachingNoticeDetail: Identifiable, Codable, Equatable {
    public let id: Int
    public let title: String
    public let contentHTML: String
    public let publishTimeText: String
    public let createUser: String?
    public let attachments: [TeachingNoticeAttachment]

    public init(
        id: Int,
        title: String,
        contentHTML: String,
        publishTimeText: String,
        createUser: String?,
        attachments: [TeachingNoticeAttachment] = []
    ) {
        self.id = id
        self.title = title
        self.contentHTML = contentHTML
        self.publishTimeText = publishTimeText
        self.createUser = createUser
        self.attachments = attachments
    }

    public var publishDate: Date {
        TeachingNotice.parseDate(publishTimeText) ?? .distantPast
    }

    public var displayDate: String {
        guard publishDate > .distantPast else { return publishTimeText }
        return TeachingNotice(id: id, title: title, publishTimeText: publishTimeText, topStatus: "0", read: true).displayDate
    }
}
