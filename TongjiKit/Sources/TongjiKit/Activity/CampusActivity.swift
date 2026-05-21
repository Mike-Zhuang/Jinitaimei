import Foundation
import SwiftData

/// 卓越星（STAR）活动条目。对齐 wish_drom `CampusActivity`。
@Model
public final class CampusActivity {
    /// STAR 平台活动 ID（用于详情跳转链接）。
    @Attribute(.unique) public var remoteId: Int64 = 0
    public var title: String = ""
    public var source: String = "STAR平台"
    public var activityDate: Date = Date.distantPast
    public var location: String?
    public var link: String?
    public var descriptionText: String?
    public var syncTime: Date = Date()

    public init(
        remoteId: Int64,
        title: String,
        source: String,
        activityDate: Date,
        location: String?,
        link: String?,
        descriptionText: String?,
        syncTime: Date
    ) {
        self.remoteId = remoteId
        self.title = title
        self.source = source
        self.activityDate = activityDate
        self.location = location
        self.link = link
        self.descriptionText = descriptionText
        self.syncTime = syncTime
    }
}
