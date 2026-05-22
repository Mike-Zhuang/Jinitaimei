import SwiftUI

/// 全局登录页展示控制器。
///
/// 多个页面可能同时显示 `AuthStateBanner`。如果每个 banner 都各自 present
/// `LoginPage`，SwiftUI 会出现 already presenting 警告甚至白屏。这里把交互登录
/// 收敛到 RootView 的单一出口。
@MainActor
public final class LoginPresentationModel: ObservableObject {

    public static let shared = LoginPresentationModel()

    @Published public var isPresented = false

    private init() {}

    public func requestLogin() {
        guard !isPresented else { return }
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
    }
}
