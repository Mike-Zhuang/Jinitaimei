import Foundation

/// 同济大学课表节次时间表。
///
/// 时间表参考 `wish_drom/Services/Plugins/SchedulePlugin.cs` 的 `FormatPeriodTime`，
/// 并补全到 12 节以覆盖晚间扩展课时。
public struct TongjiTimeSlot: Identifiable, Hashable, Sendable {
    public let id: Int       // 1-based 节次编号
    public let start: String // "HH:mm"
    public let end: String   // "HH:mm"

    public init(_ id: Int, _ start: String, _ end: String) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public extension TongjiTimeSlot {
    /// 同济四平路校区常用作息时间（与 wish_drom 一致）。
    static let list: [TongjiTimeSlot] = [
        TongjiTimeSlot(1, "08:00", "08:45"),
        TongjiTimeSlot(2, "08:55", "09:40"),
        TongjiTimeSlot(3, "10:00", "10:45"),
        TongjiTimeSlot(4, "10:55", "11:40"),
        TongjiTimeSlot(5, "14:00", "14:45"),
        TongjiTimeSlot(6, "14:55", "15:40"),
        TongjiTimeSlot(7, "16:00", "16:45"),
        TongjiTimeSlot(8, "16:55", "17:40"),
        TongjiTimeSlot(9, "19:00", "19:45"),
        TongjiTimeSlot(10, "19:55", "20:40"),
        TongjiTimeSlot(11, "20:50", "21:35"),
        TongjiTimeSlot(12, "21:45", "22:30")
    ]
}
