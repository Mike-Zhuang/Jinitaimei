import Foundation

/// 一系统会话接口。
public final class SessionAPI {
    private let apiHost = "https://1.tongji.edu.cn"
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    /// 拉取并缓存当前登录用户资料。
    public func refreshSessionUser() async throws -> TongjiUserProfile {
        guard let cookie = store.get(CredentialStore.Keys.tongjiCookies), !cookie.isEmpty else {
            throw AuthError.notLoggedIn("未找到登录凭证，请先完成登录")
        }
        let sessionId = store.get(CredentialStore.Keys.tongjiSessionId) ?? ""
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "\(apiHost)/api/sessionservice/session/getSessionUser?_t=\(timestamp)")!

        var request = URLRequest(url: url)
        applyAuthHeaders(&request, cookie: cookie, sessionId: sessionId)

        let (data, response) = try await session.data(for: request)
        try ensureAuth(response: response)

        let payload = try JSONDecoder().decode(SessionUserResponse.self, from: data)
        guard payload.code == 200, let data = payload.data else {
            throw AuthError.loginFlowFailed(payload.msg.isEmpty ? "个人信息响应异常" : payload.msg)
        }

        let user = data.user
        let profile = TongjiUserProfile(
            uid: data.uid,
            name: user.extend?.userName ?? user.name,
            facultyName: user.facultyName,
            deptOrMajor: user.extend?.deptOrMajor,
            grade: user.grade ?? user.extend?.currentGrade,
            loginTime: user.loginTime,
            lastLoginTime: user.lastLoginTime,
            sexCode: user.sex.map(String.init),
            typeCode: user.type.map(String.init),
            innerRoles: user.innerRoles ?? [],
            photoPath: user.extend?.photoPath
        )
        cache(profile)
        return profile
    }

    private func cache(_ profile: TongjiUserProfile) {
        store.set(profile.uid, for: CredentialStore.Keys.tongjiUid)
        store.set(profile.name, for: CredentialStore.Keys.tongjiUserName)
        setIfPresent(profile.facultyName, for: CredentialStore.Keys.tongjiFacultyName)
        setIfPresent(profile.deptOrMajor, for: CredentialStore.Keys.tongjiDeptOrMajor)
        setIfPresent(profile.grade, for: CredentialStore.Keys.tongjiGrade)
        setIfPresent(profile.loginTime, for: CredentialStore.Keys.tongjiLoginTime)
        setIfPresent(profile.lastLoginTime, for: CredentialStore.Keys.tongjiLastLoginTime)
        setIfPresent(profile.sexCode, for: CredentialStore.Keys.tongjiUserSexCode)
        setIfPresent(profile.typeCode, for: CredentialStore.Keys.tongjiUserTypeCode)
        setIfPresent(profile.photoPath, for: CredentialStore.Keys.tongjiPhotoPath)
        store.set(profile.innerRoles.joined(separator: ","), for: CredentialStore.Keys.tongjiInnerRoles)
    }

    private func setIfPresent(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            store.set(value, for: key)
        } else {
            store.remove(key)
        }
    }

    private func applyAuthHeaders(_ request: inout URLRequest, cookie: String, sessionId: String) {
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Token")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
    }

    private func ensureAuth(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            store.remove(CredentialStore.Keys.tongjiCookies)
            store.remove(CredentialStore.Keys.tongjiSessionId)
            throw AuthError.expired("凭证已失效，请重新登录")
        }
        if !(200..<300).contains(http.statusCode) {
            throw AuthError.loginFlowFailed("HTTP \(http.statusCode)")
        }
    }
}

private struct SessionUserResponse: Decodable {
    let code: Int
    let msg: String
    let data: SessionUserData?
}

private struct SessionUserData: Decodable {
    let uid: String
    let user: SessionUser
}

private struct SessionUser: Decodable {
    let name: String
    let sex: Int?
    let type: Int?
    let innerRoles: [String]?
    let facultyName: String?
    let grade: String?
    let loginTime: String?
    let lastLoginTime: String?
    let extend: SessionUserExtend?
}

private struct SessionUserExtend: Decodable {
    let currentGrade: String?
    let photoPath: String?
    let deptOrMajor: String?
    let userName: String?
}
