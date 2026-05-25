import Foundation

public enum CampusCardFormat {
    public static func balance(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}
