import Foundation

/// 卓越星个人星值摘要。
///
/// STAR 接口还会返回若干 `Power` 能力值，当前 UI 只展示总星值与五类星值，避免信息过载。
public struct StarScoreSummary: Codable, Equatable, Sendable {
    public let totalScore: Double
    public let currentLevel: Int?
    public let nextLevelScore: Double?
    public let hongwenScore: Double
    public let hongwenStage: Int?
    public let mingdeScore: Double
    public let mingdeStage: Int?
    public let shizhiScore: Double
    public let shizhiStage: Int?
    public let qiusuoScore: Double
    public let qiusuoStage: Int?
    public let lixingScore: Double
    public let lixingStage: Int?

    public init(
        totalScore: Double,
        currentLevel: Int?,
        nextLevelScore: Double?,
        hongwenScore: Double,
        hongwenStage: Int?,
        mingdeScore: Double,
        mingdeStage: Int?,
        shizhiScore: Double,
        shizhiStage: Int?,
        qiusuoScore: Double,
        qiusuoStage: Int?,
        lixingScore: Double,
        lixingStage: Int?
    ) {
        self.totalScore = totalScore
        self.currentLevel = currentLevel
        self.nextLevelScore = nextLevelScore
        self.hongwenScore = hongwenScore
        self.hongwenStage = hongwenStage
        self.mingdeScore = mingdeScore
        self.mingdeStage = mingdeStage
        self.shizhiScore = shizhiScore
        self.shizhiStage = shizhiStage
        self.qiusuoScore = qiusuoScore
        self.qiusuoStage = qiusuoStage
        self.lixingScore = lixingScore
        self.lixingStage = lixingStage
    }
}

public extension StarScoreSummary {
    static func load(from store: CredentialStore = .shared) -> StarScoreSummary? {
        guard let json = store.get(CredentialStore.Keys.starScoreSummary),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(StarScoreSummary.self, from: data)
    }

    func cache(to store: CredentialStore = .shared) {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        store.set(json, for: CredentialStore.Keys.starScoreSummary)
    }

    static func formatScore(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
