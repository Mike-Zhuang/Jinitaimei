import Foundation

/// 卓越星 STAR 平台 API 客户端。
///
/// 实测发现：H5 端 `/api/app-api/activity/index/list` 是 **公开接口**，无需鉴权。
/// SPA 在 `star.tongji.edu.cn/app/` 上调用时不带 Authorization 头也能正常返回数据。
/// 因此这里有 Bearer Token 就带上（兼容未来可能的接口收紧），没有则匿名调用。
///
/// 分页协议：每页 10 条，直到本页 < 10 条停止。
public final class ActivityAPI {

    private let apiBase = URL(string: "https://star.tongji.edu.cn")!
    private let pageSize = 10
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    /// 拉取全部活动的原始 JSON 项目数组（每个元素是一条活动的 JSON 字符串）。
    public func fetchAllActivitiesRaw() async throws -> [String] {
        let token = store.get(CredentialStore.Keys.starBearerToken)

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

            // 业务码检查
            if let code = (dict["code"] as? Int) ?? (dict["code"] as? NSNumber)?.intValue {
                if code == 401 || code == 403 {
                    store.remove(CredentialStore.Keys.starBearerToken)
                    throw AuthError.expired("STAR 平台凭证已失效，请重新登录")
                }
                if code != 0 { break }
            }

            guard let dataObj = dict["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else {
                break
            }

            // 每条转回 JSON 字符串，便于上层用 JSONUtils 解析
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

    private func ensureAuth(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            store.remove(CredentialStore.Keys.starBearerToken)
            throw AuthError.expired("STAR 平台凭证已失效，请重新登录")
        }
        if !(200..<300).contains(http.statusCode) {
            throw AuthError.loginFlowFailed("HTTP \(http.statusCode)")
        }
    }
}
