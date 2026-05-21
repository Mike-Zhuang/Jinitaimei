import SwiftUI
import SwiftData
import TongjiKit

/// 校园服务首页（精简版）。
///
/// 复旦 DanXi-swift 的 `CampusHome` 罗列了图书馆、食堂、巴士、电费、教务通知等
/// 十余个服务入口，此处仅保留"卓越星活动"一项。新增服务时往下面追加 NavigationLink。
public struct CampusHome: View {

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ActivityListPageContainer()
                    } label: {
                        Label("卓越星活动", systemImage: "star.circle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("校园服务")
        }
    }
}

/// 仅用于在 NavigationLink 中拿到 modelContext。
private struct ActivityListPageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        ActivityListPage(modelContext: modelContext)
    }
}
