import Foundation
import SwiftData

@MainActor
public final class YikatongStore: ObservableObject {
    @Published public private(set) var snapshots: [CampusCardBalanceSnapshot] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let api: YikatongAPI
    private let context: ModelContext

    public init(modelContext: ModelContext, api: YikatongAPI = YikatongAPI()) {
        self.context = modelContext
        self.api = api
        loadFromLocal()
    }

    public var latestSnapshot: CampusCardBalanceSnapshot? {
        snapshots.first
    }

    public func loadFromLocal() {
        let descriptor = FetchDescriptor<CampusCardBalanceSnapshot>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        do {
            snapshots = try context.fetch(descriptor)
        } catch {
            snapshots = []
            lastError = error.localizedDescription
        }
    }

    public func sync() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        do {
            let payload = try await api.fetchBalance()
            try persist(payload)
            loadFromLocal()
            if let latestSnapshot {
                await CampusNotificationDetector.shared.processCampusCardBalance(latestSnapshot)
            }
        } catch let error as AuthError {
            lastError = error.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func clearLocalData() {
        do {
            try clearAll()
            try context.save()
            snapshots = []
            lastError = nil
        } catch {
            snapshots = []
            lastError = error.localizedDescription
        }
    }

    private func persist(_ payload: CampusCardBalancePayload) throws {
        let latest = latestSnapshot
        if let latest,
           abs(latest.balanceYuan - payload.balanceYuan) < 0.0001,
           payload.capturedAt.timeIntervalSince(latest.capturedAt) < 900 {
            latest.capturedAt = payload.capturedAt
            latest.account = payload.account
            latest.ownerName = payload.ownerName
            latest.cardIdentifier = payload.cardIdentifier
            try context.save()
            return
        }

        let snapshot = CampusCardBalanceSnapshot(
            capturedAt: payload.capturedAt,
            balanceYuan: payload.balanceYuan,
            account: payload.account,
            ownerName: payload.ownerName,
            cardIdentifier: payload.cardIdentifier
        )
        context.insert(snapshot)
        try pruneHistory(maxCount: 120)
        try context.save()
    }

    private func pruneHistory(maxCount: Int) throws {
        let descriptor = FetchDescriptor<CampusCardBalanceSnapshot>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        guard all.count > maxCount else { return }
        for snapshot in all.suffix(from: maxCount) {
            context.delete(snapshot)
        }
    }

    private func clearAll() throws {
        let descriptor = FetchDescriptor<CampusCardBalanceSnapshot>()
        let all = try context.fetch(descriptor)
        for snapshot in all {
            context.delete(snapshot)
        }
    }
}
