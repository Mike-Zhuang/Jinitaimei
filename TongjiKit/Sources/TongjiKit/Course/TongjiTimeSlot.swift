import Foundation

/// 同济大学课表节次时间表。
///
/// 数据来源：同济大学官方《作息时间表》（共 11 节）。
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
    /// 同济大学官方作息时间（11 节）。
    static let list: [TongjiTimeSlot] = [
        TongjiTimeSlot(1, "08:00", "08:45"),
        TongjiTimeSlot(2, "08:50", "09:35"),
        TongjiTimeSlot(3, "10:00", "10:45"),
        TongjiTimeSlot(4, "10:50", "11:35"),
        TongjiTimeSlot(5, "13:30", "14:15"),
        TongjiTimeSlot(6, "14:20", "15:05"),
        TongjiTimeSlot(7, "15:30", "16:15"),
        TongjiTimeSlot(8, "16:20", "17:05"),
        TongjiTimeSlot(9, "18:30", "19:15"),
        TongjiTimeSlot(10, "19:20", "20:05"),
        TongjiTimeSlot(11, "20:10", "20:55")
    ]
}
