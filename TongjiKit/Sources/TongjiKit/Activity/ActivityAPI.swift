import Foundation

/// 卓越星 STAR 平台 API 客户端。
///
/// - `fetchAllActivitiesRaw`：公开接口（H5 端），无需 Bearer Token；
///   有就带上提高兼容性。
/// - `fetchStarScoreSummary`：必须 Bearer Token。
///
/// 公方法走 `withStarAuthRetry`，401 时让 `StarAuthCoordinator` 跑续期再重试一次；
/// **不**触发一系统的 `CampusModel.authState` 任何变化。
public final class ActivityAPI {

    private let apiBase = URL(string: "https://star.tongji.edu.cn")!
    private let pageSize = 10
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func fetchAllActivitiesRaw() async throws -> [String] {
        try await withStarAuthRetry { [self] in
            try await fetchAllActivitiesRawOnce()
        }
    }

    public func fetchStarScoreSummary() async throws -> StarScoreSummary {
        try await withStarAuthRetry { [self] in
            try await fetchStarScoreSummaryOnce()
        }
    }

    // MARK: - Once 版本

    public func fetchAllActivitiesRawOnce() async throws -> [String] {
        let token = validTokenOrNil()

        var all: [String] = []
        var pageNo = 1
        while true {
            let url = URL(string:
                "\(apiBase.absoluteString)/api/app-api/activity/index/list" +
                "?pageNo=\(pageNo)&pageSize=\(pageSize)&recommend=1"
            )!
            var request = URLRequest(url: url)
            applyAuthHeaders(&request, token: token)

            let (data, response) = try await session.data(for: request)
            try ensureAuth(response: response)

            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                break
            }

            if let code = (dict["code"] as? Int) ?? (dict["code"] as? NSNumber)?.intValue {
                if code == 401 || code == 403 {
                    throw AuthError.expired("STAR 平台凭证已失效")
                }
                if code != 0 { break }
            }

            guard let dataObj = dict["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else {
                break
            }

            let chunk: [String] = list.compactMap { item in
                if let d = try? JSONSerialization.data(withJSONObject: item),
                   let s = String(data: d, encoding: .utf8) {
                    return s
                }
                return nil
            }
            all.append(contentsOf: chunk)

            if chunk.count < pageSize { break }
            pageNo += 1
        }
        return all
    }

    public func fetchStarScoreSummaryOnce() async throws -> StarScoreSummary {
        guard let token = validTokenOrNil() else {
            throw AuthError.expired("未找到 STAR 平台登录凭证")
        }

        let url = URL(string: "\(apiBase.absoluteString)/api/app-api/activity/statistics/start-count")!
        var request = URLRequest(url: url)
        applyAuthHeaders(&request, token: token)
        request.setValue(apiBase.absoluteString, forHTTPHeaderField: "X-Request-Origin")

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response)

        let payload = try JSONDecoder().decode(StarScoreResponse.self, from: data)
        if payload.code == 401 || payload.code == 403 {
            throw AuthError.expired("STAR 平台凭证已失效")
        }
        guard payload.code == 0, let data = payload.data else {
            throw AuthError.loginFlowFailed(payload.msg?.isEmpty == false ? payload.msg! : "卓越星个人星值响应异常")
        }

        let summary = StarScoreSummary(
            totalScore: data.totalScore ?? 0,
            currentLevel: data.currentLevel,
            nextLevelScore: data.nextLevelScore,
            hongwenScore: data.hongwenScore ?? 0,
            hongwenStage: data.hongwenStage,
            mingdeScore: data.mingdeScore ?? 0,
            mingdeStage: data.mingdeStage,
            shizhiScore: data.shizhiScore ?? 0,
            shizhiStage: data.shizhiStage,
            qiusuoScore: data.qiusuoScore ?? 0,
            qiusuoStage: data.qiusuoStage,
            lixingScore: data.lixingScore ?? 0,
            lixingStage: data.lixingStage
        )
        summary.cache(to: store)
        return summary
    }

    private func applyAuthHeaders(_ request: inout URLRequest, token: String?) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("h5", forHTTPHeaderField: "Platform")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15
    }

    private func validTokenOrNil() -> String? {
        guard let token = store.get(CredentialStore.Keys.starBearerToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= 20,
              token.lowercased() != "bearer" else {
            return nil
        }
        return token
    }

    /// 401/403 仅抛 `AuthError.expired`；交给 `StarAuthCoordinator` 续期。
    private func ensureAuth(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AuthError.expired("STAR 平台凭证已失效")
        }
        if !(200..<300).contains(http.statusCode) {
            throw AuthError.loginFlowFailed("HTTP \(http.statusCode)")
        }
    }
}

private struct StarScoreResponse: Decodable {
    let code: Int
    let data: StarScoreData?
    let msg: String?
}

private struct StarScoreData: Decodable {
    let totalScore: Double?
    let currentLevel: Int?
    let nextLevelScore: Double?
    let hongwenScore: Double?
    let hongwenStage: Int?
    let mingdeScore: Double?
    let mingdeStage: Int?
    let shizhiScore: Double?
    let shizhiStage: Int?
    let qiusuoScore: Double?
    let qiusuoStage: Int?
    let lixingScore: Double?
    let lixingStage: Int?
}
