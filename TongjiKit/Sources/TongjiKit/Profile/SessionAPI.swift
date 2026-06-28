import Foundation

/// 一系统会话接口。
public final class SessionAPI {
    private let store: CredentialStore
    private let httpClient: TongjiHTTPClient

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.httpClient = TongjiHTTPClient(store: store, session: session)
    }

    /// 公开 API：自带 `withAuthRetry` 单次重试。
    public func refreshSessionUser() async throws -> TongjiUserProfile {
        try await withAuthRetry { [self] in
            try await refreshSessionUserOnce()
        }
    }

    /// 内部一次性版本：**不**触发续期，专供 `TongjiAuthCoordinator` /
    /// `CampusModel.performScenePhaseCheckIfDue` 等需要避免递归的入口调用。
    /// 401 / 403 时仅 `throw AuthError.expired`，**绝不清 Keychain**。
    @discardableResult
    public func refreshSessionUserOnce() async throws -> TongjiUserProfile {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let request = try httpClient.request(
            endpoint: .oneSystem,
            path: "/api/sessionservice/session/getSessionUser",
            queryItems: [URLQueryItem(name: "_t", value: "\(timestamp)")],
            headers: ["Accept": "application/json"],
            timeout: 15
        )

        let data = try await httpClient.data(for: request, endpoint: .oneSystem)

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
