import Foundation

/// 解析单条 STAR 活动 JSON 为 `CampusActivity`。
/// 移植自 wish_drom `StarActivityProvider.ParseActivitiesFromRawData`。
public enum ActivityParser {

    /// 卓越星五大模块的中文名映射。
    public static let categoryNameMap: [String: String] = [
        "lixing": "力行之星",
        "qiusuo": "求索之星",
        "hongwen": "弘文之星",
        "mingde": "明德之星",
        "shizhi": "矢志之星"
    ]

    public static func parse(rawJSONStrings: [String], now: Date = Date()) -> [CampusActivity] {
        var result: [CampusActivity] = []
        for raw in rawJSONStrings {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let title = string(obj, "title"), !title.isEmpty else { continue }

            let remoteId = long(obj, "id") ?? 0
            let date = timestampToDate(obj, "activityStartTime") ?? Date.distantPast
            let endDate = timestampToDate(obj, "activityEndTime")
            let source = string(obj, "mainBoardUnit") ?? "STAR平台"
            let location = string(obj, "addr")
            let link = buildActivityLink(id: remoteId)

            var descParts: [String] = []
            let moduleCode = string(obj, "module")
            let moduleName = moduleCode.flatMap { categoryNameMap[$0] } ?? moduleCode
            if let moduleName {
                descParts.append(moduleName)
            }
            let progress = obj["progress"] as? [String: Any]
            let progressValue = progress.flatMap { int($0, "value") }
            let progressName = progress.flatMap { string($0, "name") }
            if let progressName, !progressName.isEmpty {
                descParts.append(progressName)
            }
            let points = double(obj, "points") ?? 0
            if points > 0 {
                descParts.append("星星数量: \(formatPoints(points))")
            }
            if let pageViews = int(obj, "pageViews"), pageViews > 0 {
                descParts.append("浏览: \(pageViews)")
            }
            let description = descParts.isEmpty ? nil : descParts.joined(separator: " | ")

            result.append(CampusActivity(
                remoteId: remoteId,
                title: title,
                source: source,
                activityDate: date,
                activityEndDate: endDate,
                location: location,
                link: link,
                descriptionText: description,
                progressValue: progressValue,
                progressName: progressName,
                moduleCode: moduleCode,
                moduleName: moduleName,
                starPoints: points,
                syncTime: now
            ))
        }
        return result
    }

    private static func buildActivityLink(id: Int64) -> String? {
        guard id > 0 else { return nil }
        return "https://star.tongji.edu.cn/app/pages/activity/detail?id=\(id)"
    }

    private static func formatPoints(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private static func string(_ dict: [String: Any], _ key: String) -> String? {
        if let s = dict[key] as? String { return s.isEmpty ? nil : s }
        if let n = dict[key] as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let n = dict[key] as? Int { return n }
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String { return Int(s) }
        return nil
    }

    private static func long(_ dict: [String: Any], _ key: String) -> Int64? {
        if let n = dict[key] as? Int64 { return n }
        if let n = dict[key] as? NSNumber { return n.int64Value }
        if let s = dict[key] as? String { return Int64(s) }
        return nil
    }

    private static func double(_ dict: [String: Any], _ key: String) -> Double? {
        if let n = dict[key] as? Double { return n }
        if let n = dict[key] as? NSNumber { return n.doubleValue }
        if let s = dict[key] as? String { return Double(s) }
        return nil
    }

    private static func timestampToDate(_ dict: [String: Any], _ key: String) -> Date? {
        guard let ms = long(dict, key), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
}
