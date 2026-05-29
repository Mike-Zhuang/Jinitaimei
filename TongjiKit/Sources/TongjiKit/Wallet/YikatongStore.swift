import Foundation
import os.log
import SwiftData

@MainActor
public final class YikatongStore: ObservableObject {
    @Published public private(set) var snapshots: [CampusCardBalanceSnapshot] = []
    @Published public private(set) var transactions: [CampusCardTransaction] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let api: YikatongAPI
    private let context: ModelContext
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "YikatongStore")
    private static var activeSyncTask: Task<Void, Never>?
    private static var fullSyncTask: Task<Void, Never>?
    private static var lastSuccessfulQuickSync: Date?
    private static let cacheFreshnessInterval: TimeInterval = 60

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
        let transactionDescriptor = FetchDescriptor<CampusCardTransaction>(
            sortBy: [SortDescriptor(\.transactionDateTime, order: .reverse)]
        )
        do {
            snapshots = try context.fetch(descriptor)
            transactions = try context.fetch(transactionDescriptor)
        } catch {
            snapshots = []
            transactions = []
            lastError = error.localizedDescription
            log("本地校园卡数据加载失败：\(error.localizedDescription)")
        }
    }

    public func sync(force: Bool = false, mode: YikatongTransactionFetchMode = .quick) async {
        guard !isLoading else { return }
        if !force, isCacheFresh(mode: mode) {
            log("校园卡缓存仍新鲜，跳过本轮网络同步")
            loadFromLocal()
            return
        }
        if let activeTask = Self.activeSyncTask {
            log("已有校园卡同步任务在运行，复用结果")
            await activeTask.value
            loadFromLocal()
            return
        }

        isLoading = true
        lastError = nil

        let task = Task { @MainActor in
            await performSync(mode: mode)
        }
        Self.activeSyncTask = task
        await task.value
        Self.activeSyncTask = nil
        isLoading = false

        if mode == .quick {
            scheduleFullSyncIfNeeded()
        }
    }

    public func clearLocalData() {
        do {
            try clearAll()
            try context.save()
            snapshots = []
            transactions = []
            lastError = nil
        } catch {
            snapshots = []
            transactions = []
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

    private func performSync(mode: YikatongTransactionFetchMode) async {
        do {
            log("开始同步校园卡余额与消费记录（\(mode == .quick ? "快速" : "完整")）")
            let payload = try await api.fetchBalance()
            try persist(payload)
            log("校园卡余额同步成功：¥\(CampusCardFormat.balance(payload.balanceYuan))")

            do {
                let transactionPayloads = try await api.fetchTransactions(maxPages: mode.maxPages)
                try persistTransactions(transactionPayloads)
                log("校园卡消费记录同步成功：\(transactionPayloads.count) 条")
            } catch {
                log("校园卡消费记录同步失败（不影响余额展示）：\(error.localizedDescription)")
            }

            Self.lastSuccessfulQuickSync = Date()
            loadFromLocal()
            if let latestSnapshot {
                await CampusNotificationDetector.shared.processCampusCardBalance(latestSnapshot)
            }
        } catch let error as AuthError {
            lastError = error.errorDescription
            log("校园卡同步失败（鉴权）: \(error.errorDescription ?? error.localizedDescription)")
        } catch {
            lastError = error.localizedDescription
            log("校园卡同步失败：\(error.localizedDescription)")
        }
    }

    private func scheduleFullSyncIfNeeded() {
        guard Self.fullSyncTask == nil else { return }
        Self.fullSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await sync(force: true, mode: .full)
            Self.fullSyncTask = nil
        }
    }

    private func isCacheFresh(mode: YikatongTransactionFetchMode) -> Bool {
        guard mode == .quick,
              let latestSnapshot,
              !transactions.isEmpty,
              let lastSuccessfulQuickSync = Self.lastSuccessfulQuickSync else {
            return false
        }
        let now = Date()
        return now.timeIntervalSince(latestSnapshot.capturedAt) < Self.cacheFreshnessInterval &&
            now.timeIntervalSince(lastSuccessfulQuickSync) < Self.cacheFreshnessInterval
    }

    private func persistTransactions(_ payloads: [CampusCardTransactionPayload]) throws {
        guard !payloads.isEmpty else { return }
        let descriptor = FetchDescriptor<CampusCardTransaction>()
        let existing = try context.fetch(descriptor)
        var existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.orderId, $0) })

        for payload in payloads {
            if let transaction = existingMap[payload.orderId] {
                transaction.transactionDateTime = payload.transactionDateTime
                transaction.amountYuan = payload.amountYuan
                transaction.balanceYuan = payload.balanceYuan
                transaction.transactionDescription = payload.transactionDescription
                transaction.turnoverType = payload.turnoverType
                transaction.locationName = payload.locationName
                transaction.payName = payload.payName
                transaction.updatedAt = payload.updatedAt
            } else {
                let transaction = CampusCardTransaction(
                    orderId: payload.orderId,
                    transactionDateTime: payload.transactionDateTime,
                    amountYuan: payload.amountYuan,
                    balanceYuan: payload.balanceYuan,
                    transactionDescription: payload.transactionDescription,
                    turnoverType: payload.turnoverType,
                    locationName: payload.locationName,
                    payName: payload.payName,
                    updatedAt: payload.updatedAt
                )
                context.insert(transaction)
                existingMap[payload.orderId] = transaction
            }
        }

        try pruneTransactions(maxCount: 600)
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

    private func pruneTransactions(maxCount: Int) throws {
        let descriptor = FetchDescriptor<CampusCardTransaction>(
            sortBy: [SortDescriptor(\.transactionDateTime, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        guard all.count > maxCount else { return }
        for transaction in all.suffix(from: maxCount) {
            context.delete(transaction)
        }
    }

    private func clearAll() throws {
        let descriptor = FetchDescriptor<CampusCardBalanceSnapshot>()
        let all = try context.fetch(descriptor)
        for snapshot in all {
            context.delete(snapshot)
        }

        let transactionDescriptor = FetchDescriptor<CampusCardTransaction>()
        let allTransactions = try context.fetch(transactionDescriptor)
        for transaction in allTransactions {
            context.delete(transaction)
        }
    }

    private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        print("[YikatongStore] \(message)")
    }
}
