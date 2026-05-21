import Foundation

/// 一系统会话中的用户基础资料。
///
/// 状态码字段仅缓存原值。HAR 中没有稳定字典，界面优先展示服务端已经返回的中文字段。
public struct TongjiUserProfile: Equatable, Sendable {
    public let uid: String
    public let name: String
    public let facultyName: String?
    public let deptOrMajor: String?
    public let grade: String?
    public let loginTime: String?
    public let lastLoginTime: String?
    public let sexCode: String?
    public let typeCode: String?
    public let innerRoles: [String]
    public let photoPath: String?

    public init(
        uid: String,
        name: String,
        facultyName: String?,
        deptOrMajor: String?,
        grade: String?,
        loginTime: String?,
        lastLoginTime: String?,
        sexCode: String?,
        typeCode: String?,
        innerRoles: [String],
        photoPath: String?
    ) {
        self.uid = uid
        self.name = name
        self.facultyName = facultyName
        self.deptOrMajor = deptOrMajor
        self.grade = grade
        self.loginTime = loginTime
        self.lastLoginTime = lastLoginTime
        self.sexCode = sexCode
        self.typeCode = typeCode
        self.innerRoles = innerRoles
        self.photoPath = photoPath
    }
}

public extension TongjiUserProfile {
    static func load(from store: CredentialStore = .shared) -> TongjiUserProfile? {
        guard let uid = store.get(CredentialStore.Keys.tongjiUid), !uid.isEmpty else {
            return nil
        }
        let name = store.get(CredentialStore.Keys.tongjiUserName) ?? uid
        let roles = store.get(CredentialStore.Keys.tongjiInnerRoles)?
            .split(separator: ",")
            .map { String($0) } ?? []

        return TongjiUserProfile(
            uid: uid,
            name: name,
            facultyName: store.get(CredentialStore.Keys.tongjiFacultyName),
            deptOrMajor: store.get(CredentialStore.Keys.tongjiDeptOrMajor),
            grade: store.get(CredentialStore.Keys.tongjiGrade),
            loginTime: store.get(CredentialStore.Keys.tongjiLoginTime),
            lastLoginTime: store.get(CredentialStore.Keys.tongjiLastLoginTime),
            sexCode: store.get(CredentialStore.Keys.tongjiUserSexCode),
            typeCode: store.get(CredentialStore.Keys.tongjiUserTypeCode),
            innerRoles: roles,
            photoPath: store.get(CredentialStore.Keys.tongjiPhotoPath)
        )
    }
}
