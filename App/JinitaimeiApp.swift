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
                    SchoolCalendarTerm.self,
                    CourseSchedule.self,
                    CampusActivity.self,
                    CampusCardBalanceSnapshot.self,
                    CampusCardTransaction.self,
                    ExamScheduleItem.self,
                    GradeSummarySnapshot.self,
                    GradeCourseRecord.self,
                    LibrarySpaceOverviewSnapshot.self,
                    LibrarySpaceAreaSnapshot.self,
                    LibrarySpaceRoomSnapshot.self,
                    WaterControlGroupSnapshot.self,
                    WaterControlDeviceSnapshot.self,
                    LaundryRoomSnapshot.self,
                    LaundryMachineSnapshot.self
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
