import Foundation

/// 鉴权失败异常，对应 wish_drom 中的 `AuthExpiredException`。
public enum AuthError: LocalizedError, Equatable {
    /// 用户尚未登录或凭证已被清除。
    case notLoggedIn(String)
    /// 凭证已过期（HTTP 401 / 403 / 业务码 401 / 403）。
    case expired(String)
    /// 登录流程中 WebView 出错或被用户取消。
    case loginFlowFailed(String)
    /// 自动密码回填遇到验证码 / 多因素验证，必须降级到交互登录。
    case mfaRequired(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn(let msg), .expired(let msg),
             .loginFlowFailed(let msg), .mfaRequired(let msg):
            return msg
        }
    }

    /// 用于 retry wrapper 判定：是否属于"可以尝试静默续期"的过期错误。
    public var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }
}
