import SwiftUI
import SwiftData
import TongjiKit

/// App 根视图：两个 Tab + 未登录拦截。
///
/// 对应 DanXi-swift `Shared/ContentView.swift` 的角色，但极度精简——
/// 没有 forum/树洞、没有 settings、没有 watchOS 分支、没有自适应宽屏。
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

/// Container 用来把 modelContext 注入 CoursePage（CoursePage 在 init 里取 store）。
private struct CoursePageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        CoursePage(modelContext: modelContext)
    }
}
