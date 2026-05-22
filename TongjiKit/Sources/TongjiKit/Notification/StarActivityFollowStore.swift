import Foundation

@MainActor
public final class StarActivityFollowStore: ObservableObject {
    public static let shared = StarActivityFollowStore()

    @Published public private(set) var followedActivityIds: Set<Int64>

    private let defaults: UserDefaults
    private let key = "followedStarActivityIds"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let values = defaults.array(forKey: key) as? [Int64] ?? []
        self.followedActivityIds = Set(values)
    }

    public func isFollowed(_ remoteId: Int64) -> Bool {
        followedActivityIds.contains(remoteId)
    }

    public func toggle(_ remoteId: Int64) {
        guard remoteId > 0 else { return }
        if followedActivityIds.contains(remoteId) {
            followedActivityIds.remove(remoteId)
        } else {
            followedActivityIds.insert(remoteId)
        }
        defaults.set(followedActivityIds.sorted(), forKey: key)
    }
}
