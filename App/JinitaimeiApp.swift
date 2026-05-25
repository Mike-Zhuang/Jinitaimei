import SwiftUI
import SwiftData
import TongjiKit
import TongjiUI

@main
struct JinitaimeiApp: App {

    /// SwiftData 容器：注册全部 @Model。
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for:
                    CourseSchedule.self,
                    CampusActivity.self,
                    CampusCardBalanceSnapshot.self,
                    CampusCardTransaction.self
            )
        } catch {
            fatalError("SwiftData 初始化失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
