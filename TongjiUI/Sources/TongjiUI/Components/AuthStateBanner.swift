import SwiftUI
import TongjiKit

/// 顶部非阻塞 banner：根据 `CampusModel.authState` 显示当前会话状态。
///
/// - `.renewing` / `.expiredRecoverable`：进度提示，不打断阅读本地缓存。
/// - `.requiresInteractiveLogin`：警示文案 + "去登录"按钮，触发 `LoginPage`
///    fullScreenCover；**不会清空本地课表 / 活动列表**。
public struct AuthStateBanner: View {

    @ObservedObject private var campusModel = CampusModel.shared
    @ObservedObject private var loginPresenter = LoginPresentationModel.shared

    public init() {}

    public var body: some View {
        Group {
            if campusModel.isRefreshingAuth {
                bannerRow(
                    color: .blue,
                    icon: "arrow.triangle.2.circlepath",
                    title: "登录状态刷新中…",
                    subtitle: "正在尝试静默续期，期间可继续查看本地缓存。"
                )
            } else if campusModel.requiresInteractiveLogin {
                requiresLoginRow
            }
        }
    }

    private func bannerRow(color: Color, icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            if icon == "arrow.triangle.2.circlepath" {
                ProgressView()
            } else {
                Image(systemName: icon).foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote).bold().foregroundStyle(.primary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var requiresLoginRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("校园账户需要重新登录")
                    .font(.footnote).bold().foregroundStyle(.primary)
                Text("自动续期失败，请手动重新登录以同步最新数据。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("去登录") { loginPresenter.requestLogin() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
