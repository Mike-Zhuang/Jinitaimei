import SwiftUI
import SwiftData
import TongjiKit

/// App 根视图：两个 Tab + 未登录拦截。
///
/// 实测发现卓越星 H5 端的活动浏览接口（`/api/app-api/activity/index/list` 等）
/// 是 **公开接口**，无需 Bearer Token；因此不再做后台 token 抓取。
/// 这也避免了之前 30 秒徒劳等待造成的"卡顿"感。
public struct RootView: View {

    @StateObject private var campusModel = CampusModel.shared
    @State private var showLogin = false

    public init() {}

    public var body: some View {
        TabView {
            CoursePageContainer()
                .tabItem {
                    Label("日程", systemImage: "calendar")
                }

            CampusHome()
                .tabItem {
                    Label("校园", systemImage: "building.columns")
                }
        }
        .task {
            campusModel.refresh()
            if !campusModel.loggedIn {
                showLogin = true
            }
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginPage(onFinished: {
                showLogin = false
                campusModel.refresh()
            })
        }
    }
}

private struct CoursePageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        CoursePage(modelContext: modelContext)
    }
}
