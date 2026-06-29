import Charts
import Combine
import SwiftUI
import SwiftData
import TongjiKit

/// 校园服务首页（精简版）。
///
/// 复旦 DanXi-swift 的 `CampusHome` 罗列了图书馆、食堂、巴士、电费、教务通知等
/// 十余个服务入口，并支持置顶服务卡片；此处保留可扩展结构。
public struct CampusHome: View {

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var model = CampusHomeModel()
    @State private var showEditor = false
    @State private var refreshToken = UUID()
    @State private var isRefreshingServices = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if !campusModel.loggedIn {
                    Section {
                        ContentUnavailableView(
                            "请先登录校园账户",
                            systemImage: "person.crop.circle.badge.exclamationmark",
                            description: Text("登录后可查看卓越星、教务通知等校园服务")
                        )
                        .listEmptyRowStyle()
                    }
                } else if !model.pinnedServices.isEmpty {
                    ForEach(model.pinnedServices) { service in
                        Section {
                            NavigationLink {
                                service.destination
                            } label: {
                                service.card(refreshToken: refreshToken)
                                    .tint(.primary)
                                    .frame(height: 85, alignment: .center)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.unpin(service)
                                } label: {
                                    Image(systemName: "pin.slash.fill")
                                }
                            }
                        }
                    }
                }

                if campusModel.loggedIn {
                    Section("全部服务") {
                        ForEach(model.unpinnedServices) { service in
                            NavigationLink {
                                service.destination
                            } label: {
                                service.label
                            }
                            .swipeActions {
                                Button {
                                    model.pin(service)
                                } label: {
                                    Image(systemName: "pin.fill")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .refreshable {
                await refreshCampusServices()
            }
            .navigationTitle("校园服务")
            .toolbar {
                if campusModel.loggedIn {
                    Button("编辑") {
                        showEditor = true
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                CampusHomeEditor(model: model)
            }
        }
    }

    @MainActor
    private func refreshCampusServices() async {
        guard !isRefreshingServices else { return }
        isRefreshingServices = true
        defer { isRefreshingServices = false }

        campusModel.refresh()
        guard campusModel.loggedIn else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await campusModel.refreshProfile()
            }
            group.addTask { @MainActor in
                await campusModel.refreshStarScoreSummary()
            }
            group.addTask {
                await CampusNotificationDetector.shared.checkTeachingNoticesIfNeeded()
            }
        }

        let yikatongStore = YikatongStore(modelContext: modelContext)
        let examStore = ExamScheduleStore(modelContext: modelContext)
        let gradeStore = GradeStore(modelContext: modelContext)
        let libraryStore = LibrarySpaceStore(modelContext: modelContext)
        let waterStore = WaterControlStore(modelContext: modelContext)
        let localStores: [CampusLocalStore] = [yikatongStore, examStore, gradeStore, libraryStore, waterStore]
        localStores.forEach { $0.clearError() }

        await yikatongStore.sync(force: true)
        await examStore.sync()
        await gradeStore.sync()
        await libraryStore.sync(force: true)
        await waterStore.syncGroups(force: true)
        if let pinnedWaterGroupId = UserDefaults.standard.string(forKey: WaterControlPreferences.pinnedGroupIdKey),
           !pinnedWaterGroupId.isEmpty {
            await waterStore.syncPinnedGroup(id: pinnedWaterGroupId, force: true)
        }
        yikatongStore.loadFromLocal()
        examStore.loadFromLocal()
        gradeStore.loadFromLocal()
        libraryStore.loadFromLocal()
        waterStore.loadFromLocal()

        refreshToken = UUID()
    }
}

private enum CampusService: String, CaseIterable, Codable, Identifiable {
    case starActivity
    case teachingNotice
    case campusCard
    case examSchedule
    case gradeReport
    case librarySpace
    case waterControl

    var id: String { rawValue }

    @ViewBuilder
    var label: some View {
        switch self {
        case .starActivity:
            Label("卓越星活动", systemImage: "star.circle")
        case .teachingNotice:
            Label("教学管理信息系统通知公告", systemImage: "bell.badge")
        case .campusCard:
            Label("校园卡", systemImage: "creditcard")
        case .examSchedule:
            Label("考试安排", systemImage: "book.closed")
        case .gradeReport:
            Label("课程成绩", systemImage: "graduationcap.circle")
        case .librarySpace:
            Label("图书馆座位", systemImage: "chair.lounge")
        case .waterControl:
            Label("智能控水", systemImage: "drop.fill")
        }
    }

    @ViewBuilder
    func card(refreshToken: UUID) -> some View {
        switch self {
        case .starActivity:
            StarActivityCard(refreshToken: refreshToken)
        case .teachingNotice:
            TeachingNoticeCard(refreshToken: refreshToken)
        case .campusCard:
            CampusCardPinnedCard(refreshToken: refreshToken)
        case .examSchedule:
            ExamSchedulePinnedCard(refreshToken: refreshToken)
        case .gradeReport:
            GradeReportPinnedCard(refreshToken: refreshToken)
        case .librarySpace:
            LibrarySpacePinnedCard(refreshToken: refreshToken)
        case .waterControl:
            WaterControlPinnedCard(refreshToken: refreshToken)
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .starActivity:
            ActivityListPageContainer()
        case .teachingNotice:
            TeachingNoticePage()
        case .campusCard:
            CampusCardPageContainer()
        case .examSchedule:
            ExamSchedulePageContainer()
        case .gradeReport:
            GradeReportPageContainer()
        case .librarySpace:
            LibrarySpacePageContainer()
        case .waterControl:
            WaterControlPageContainer()
        }
    }
}

@MainActor
private final class CampusHomeModel: ObservableObject {
    @Published var pinnedServices: [CampusService] {
        didSet { save() }
    }
    @Published var unpinnedServices: [CampusService] {
        didSet { save() }
    }

    private let pinnedKey = "campus-pinned-services"
    private let unpinnedKey = "campus-unpinned-services"

    init() {
        let defaults = UserDefaults.standard
        self.pinnedServices = Self.load(key: pinnedKey, from: defaults) ?? []
        self.unpinnedServices = Self.load(key: unpinnedKey, from: defaults) ?? [.starActivity, .teachingNotice, .campusCard, .examSchedule, .gradeReport, .librarySpace, .waterControl]
        normalize()
    }

    func pin(_ service: CampusService) {
        guard unpinnedServices.contains(service) else { return }
        withAnimation {
            unpinnedServices.removeAll { $0 == service }
            pinnedServices.append(service)
        }
    }

    func unpin(_ service: CampusService) {
        guard pinnedServices.contains(service) else { return }
        withAnimation {
            pinnedServices.removeAll { $0 == service }
            unpinnedServices.append(service)
        }
    }

    private func normalize() {
        pinnedServices = Self.uniqueKnownServices(pinnedServices)
        unpinnedServices = Self.uniqueKnownServices(unpinnedServices).filter { !pinnedServices.contains($0) }
        for service in CampusService.allCases where !pinnedServices.contains(service) && !unpinnedServices.contains(service) {
            unpinnedServices.append(service)
        }
        save()
    }

    private func save() {
        Self.save(pinnedServices, key: pinnedKey)
        Self.save(unpinnedServices, key: unpinnedKey)
    }

    private static func load(key: String, from defaults: UserDefaults) -> [CampusService]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([CampusService].self, from: data)
    }

    private static func save(_ value: [CampusService], key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func uniqueKnownServices(_ services: [CampusService]) -> [CampusService] {
        var seen = Set<CampusService>()
        return services.filter { service in
            guard CampusService.allCases.contains(service), !seen.contains(service) else {
                return false
            }
            seen.insert(service)
            return true
        }
    }
}

private struct CampusHomeEditor: View {
    @ObservedObject var model: CampusHomeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("置顶服务") {
                    if model.pinnedServices.isEmpty {
                        Text("暂无置顶服务")
                            .foregroundColor(.secondary)
                    }
                    ForEach(model.pinnedServices) { service in
                        service.label
                    }
                    .onMove { indices, newOffset in
                        model.pinnedServices.move(fromOffsets: indices, toOffset: newOffset)
                    }
                    .onDelete { indices in
                        indices.map { model.pinnedServices[$0] }.forEach(model.unpin)
                    }
                }

                Section("全部服务") {
                    ForEach(model.unpinnedServices) { service in
                        HStack {
                            service.label
                            Spacer()
                            Button {
                                model.pin(service)
                            } label: {
                                Image(systemName: "pin.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .onMove { indices, newOffset in
                        model.unpinnedServices.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("编辑校园服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    dismiss()
                }
                .bold()
            }
        }
    }
}

private struct StarActivityCard: View {
    @ObservedObject private var campusModel = CampusModel.shared
    let refreshToken: UUID

    var body: some View {
        PinnedServiceCardLayout(title: "卓越星", systemImage: "star.circle.fill", color: .orange) {
            if let summary = campusModel.starScoreSummary {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(StarScoreSummary.formatScore(summary.totalScore))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("总星值")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    HStack(spacing: 9) {
                        compactScore("弘", summary.hongwenScore)
                        compactScore("明", summary.mingdeScore)
                        compactScore("矢", summary.shizhiScore)
                        compactScore("求", summary.qiusuoScore)
                        compactScore("力", summary.lixingScore)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在同步星值")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(verbatim: "283 总星值")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .redacted(reason: .placeholder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            guard campusModel.loggedIntoStar, campusModel.starScoreSummary == nil else { return }
            await campusModel.refreshStarScoreSummary()
        }
        .onChange(of: refreshToken) { _, _ in
            guard campusModel.loggedIn else { return }
            Task { await campusModel.refreshStarScoreSummary() }
        }
    }

    private func compactScore(_ name: String, _ score: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(StarScoreSummary.formatScore(score))
                .font(.caption)
                .bold()
        }
    }
}

private struct TeachingNoticeCard: View {
    @ObservedObject private var campusModel = CampusModel.shared
    let refreshToken: UUID
    @State private var latestNotice: TeachingNotice?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        PinnedServiceCardLayout(title: "教务通知", systemImage: "bell.fill", color: .blue) {
            if !campusModel.loggedIn {
                Text("登录后查看最新通知")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let latestNotice {
                VStack(alignment: .leading, spacing: 4) {
                    Text(latestNotice.title)
                        .font(.callout)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Text(latestNotice.displayDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载最新通知")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("暂无通知公告")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            guard campusModel.loggedIn, latestNotice == nil else { return }
            await loadLatestNotice()
        }
        .onChange(of: campusModel.authState) { oldState, newState in
            if newState == .loggedOut {
                latestNotice = nil
                errorMessage = nil
                return
            }
            if newState == .valid {
                let recoveredFromExpiredState = oldState == .renewing ||
                                                oldState == .expiredRecoverable ||
                                                oldState == .requiresInteractiveLogin
                Task { await loadLatestNotice(force: recoveredFromExpiredState) }
            }
        }
        .onChange(of: refreshToken) { _, _ in
            guard campusModel.loggedIn else { return }
            Task { await loadLatestNotice(force: true) }
        }
    }

    private func loadLatestNotice(force: Bool = false) async {
        guard campusModel.loggedIn, !isLoading else { return }
        if force {
            errorMessage = nil
        }
        isLoading = true
        defer { isLoading = false }

        do {
            latestNotice = try await TeachingNoticeAPI().fetchLatestNotice()
            errorMessage = nil
        } catch {
            latestNotice = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "最新通知加载失败"
        }
    }
}

private struct CampusCardPinnedCard: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared
    let refreshToken: UUID
    @StateObject private var storeHolder = CampusCardStoreHolder()

    var body: some View {
        PinnedServiceCardLayout(title: "校园卡", systemImage: "creditcard.fill", color: .blue) {
            if !campusModel.loggedIn {
                Text("登录后查看校园卡余额")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let latest = store.latestSnapshot {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "¥\(CampusCardFormat.balance(latest.balanceYuan))")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .privacySensitive()
                        Text("余额")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    Text(latest.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, store.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载校园卡余额")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("下拉刷新后同步余额")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await reloadLocalStore()
            guard let store = storeHolder.store, campusModel.loggedIn, store.latestSnapshot == nil else { return }
            await store.sync()
        }
        .onAppear {
            Task { await reloadLocalStore() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .campusCardDataDidChange)) { _ in
            Task { await reloadLocalStore() }
        }
        .onChange(of: refreshToken) { _, _ in
            guard campusModel.loggedIn else { return }
            Task {
                await prepareStoreIfNeeded()
                await storeHolder.store?.sync(force: true)
                storeHolder.store?.loadFromLocal()
            }
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            guard let store = storeHolder.store else { return }
            if !loggedIn {
                store.clearLocalData()
            }
        }
    }

    private func prepareStoreIfNeeded() async {
        if storeHolder.store == nil {
            storeHolder.store = YikatongStore(modelContext: modelContext)
        }
    }

    private func reloadLocalStore() async {
        await prepareStoreIfNeeded()
        storeHolder.store?.loadFromLocal()
    }

    private func dailySpendingPoints(from transactions: [CampusCardTransaction]) -> [CampusCardMiniChartPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: transactions.filter { $0.hasValidTransactionDate && $0.signedAmountYuan < 0 }) { transaction in
            calendar.startOfDay(for: transaction.transactionDateTime)
        }
        return grouped
            .map { date, records in
                CampusCardMiniChartPoint(
                    date: date,
                    amount: records.reduce(0) { $0 + abs($1.signedAmountYuan) }
                )
            }
            .sorted { $0.date < $1.date }
            .suffix(7)
            .map { $0 }
    }
}

private struct ExamSchedulePinnedCard: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared
    let refreshToken: UUID
    @StateObject private var storeHolder = ExamScheduleStoreHolder()

    var body: some View {
        PinnedServiceCardLayout(title: "考试安排", systemImage: "book.closed.fill", color: .indigo) {
            if !campusModel.loggedIn {
                Text("登录后查看考试安排")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let nextExam = store.nextExam {
                VStack(alignment: .leading, spacing: 4) {
                    Text(nextExam.courseName)
                        .font(.callout)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Text("\(nextExam.displayDate) \(nextExam.displayTime)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, store.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载考试安排")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let lastSync = store.lastSyncTime {
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂无近期考试")
                        .font(.callout)
                    Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("下拉刷新后同步考试安排")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await reloadLocalStore()
            guard let store = storeHolder.store, campusModel.loggedIn, store.exams.isEmpty else { return }
            await store.sync()
        }
        .onAppear {
            Task { await reloadLocalStore() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .examScheduleDataDidChange)) { _ in
            Task { await reloadLocalStore() }
        }
        .onChange(of: refreshToken) { _, _ in
            guard campusModel.loggedIn else { return }
            Task {
                await prepareStoreIfNeeded()
                await storeHolder.store?.sync()
                storeHolder.store?.loadFromLocal()
            }
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            guard let store = storeHolder.store else { return }
            if !loggedIn {
                store.clearLocalData()
            }
        }
    }

    private func prepareStoreIfNeeded() async {
        if storeHolder.store == nil {
            storeHolder.store = ExamScheduleStore(modelContext: modelContext)
        }
    }

    private func reloadLocalStore() async {
        await prepareStoreIfNeeded()
        storeHolder.store?.loadFromLocal()
    }
}

private struct GradeReportPinnedCard: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared
    let refreshToken: UUID
    @StateObject private var storeHolder = GradeStoreHolder()

    var body: some View {
        PinnedServiceCardLayout(title: "课程成绩", systemImage: "graduationcap.circle.fill", color: .green) {
            if !campusModel.loggedIn {
                Text("登录后查看课程成绩")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let summary = store.summary {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(clean(summary.totalGradePoint))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("总绩点")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    Text("实修学分 \(clean(summary.actualCredit)) · 最近学期 \(store.latestTerm?.averagePoint ?? "暂无")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, store.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载课程成绩")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("下拉刷新后同步成绩")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await reloadLocalStore()
            guard let store = storeHolder.store, campusModel.loggedIn, store.summary == nil else { return }
            await store.sync()
        }
        .onAppear {
            Task { await reloadLocalStore() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gradeReportDataDidChange)) { _ in
            Task { await reloadLocalStore() }
        }
        .onChange(of: refreshToken) { _, _ in
            guard campusModel.loggedIn else { return }
            Task {
                await prepareStoreIfNeeded()
                await storeHolder.store?.sync()
                storeHolder.store?.loadFromLocal()
            }
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            guard let store = storeHolder.store else { return }
            if !loggedIn {
                store.clearLocalData()
            }
        }
    }

    private func prepareStoreIfNeeded() async {
        if storeHolder.store == nil {
            storeHolder.store = GradeStore(modelContext: modelContext)
        }
    }

    private func reloadLocalStore() async {
        await prepareStoreIfNeeded()
        storeHolder.store?.loadFromLocal()
    }

    private func clean(_ value: String) -> String {
        guard let number = Double(value) else { return value.isEmpty ? "暂无" : value }
        if number.rounded() == number {
            return String(Int(number))
        }
        return String(format: "%.2f", number)
    }
}

private struct LibrarySpacePinnedCard: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared
    let refreshToken: UUID
    @StateObject private var storeHolder = LibrarySpaceStoreHolder()

    var body: some View {
        PinnedServiceCardLayout(title: "图书馆座位", systemImage: "chair.lounge.fill", color: .teal) {
            if !campusModel.loggedIn {
                Text("登录后查看图书馆座位")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, !store.targetLibraries.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.targetLibraries.prefix(2)) { library in
                        HStack {
                            Text(library.shortDisplayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(library.freeSeats)/\(library.totalSeats) 可用")
                                .font(.caption)
                                .bold()
                        }
                    }
                    Text("座位占用口径")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, store.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载图书馆座位")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("下拉刷新后同步座位状态")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await reloadLocalStore()
            guard let store = storeHolder.store, campusModel.loggedIn, store.libraries.isEmpty else { return }
            await store.sync()
        }
        .onAppear {
            Task { await reloadLocalStore() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .librarySpaceDataDidChange)) { _ in
            Task { await reloadLocalStore() }
        }
        .onChange(of: refreshToken) { _, _ in
            guard campusModel.loggedIn else { return }
            Task {
                await prepareStoreIfNeeded()
                await storeHolder.store?.sync(force: true)
                storeHolder.store?.loadFromLocal()
            }
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            guard let store = storeHolder.store else { return }
            if !loggedIn {
                store.clearLocalData()
            }
        }
    }

    private func prepareStoreIfNeeded() async {
        if storeHolder.store == nil {
            storeHolder.store = LibrarySpaceStore(modelContext: modelContext)
        }
    }

    private func reloadLocalStore() async {
        await prepareStoreIfNeeded()
        storeHolder.store?.loadFromLocal()
    }
}

private struct WaterControlPinnedCard: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared
    let refreshToken: UUID
    @StateObject private var storeHolder = WaterControlStoreHolder()
    @AppStorage(WaterControlPreferences.pinnedGroupIdKey) private var pinnedGroupId = ""

    var body: some View {
        PinnedServiceCardLayout(title: "智能控水", systemImage: "drop.fill", color: .cyan) {
            if !campusModel.loggedIn {
                Text("登录后查看控水器状态")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store,
                      let pinnedGroup = pinnedGroup(in: store) {
                let devices = store.devices(for: pinnedGroup)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(pinnedGroup.name)
                            .font(.callout)
                            .bold()
                            .lineLimit(1)
                        Spacer()
                    }

                    if !devices.isEmpty {
                        Text("\(devices.filter { $0.status == .available }.count)/\(devices.count) 空闲 · 使用中 \(devices.filter { $0.status == .inUse }.count)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if store.loadingGroupIds.contains(pinnedGroup.id) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在同步我的宿舍")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("下拉刷新后只同步这个宿舍")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let error = store.error(for: pinnedGroup) {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, !pinnedGroupId.isEmpty, !store.groups.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("未找到置顶宿舍")
                        .font(.callout)
                        .bold()
                    Text("进入后重新选择我的宿舍")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, !store.groups.isEmpty {
                Text("进入后置顶你的宿舍")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, store.isLoadingGroups {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载智能控水")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let store = storeHolder.store, let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("下拉刷新后同步控水状态")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await reloadLocalStore()
            guard let store = storeHolder.store, campusModel.loggedIn else { return }
            if store.groups.isEmpty {
                await store.syncGroups()
            }
            if !pinnedGroupId.isEmpty {
                await store.syncPinnedGroup(id: pinnedGroupId)
            }
        }
        .onAppear {
            Task { await reloadLocalStore() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .waterControlDataDidChange)) { _ in
            Task { await reloadLocalStore() }
        }
        .onChange(of: refreshToken) { _, _ in
            guard campusModel.loggedIn else { return }
            Task {
                await prepareStoreIfNeeded()
                await storeHolder.store?.syncGroups(force: true)
                if !pinnedGroupId.isEmpty {
                    await storeHolder.store?.syncPinnedGroup(id: pinnedGroupId, force: true)
                }
                storeHolder.store?.loadFromLocal()
            }
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            guard let store = storeHolder.store else { return }
            if !loggedIn {
                store.clearLocalData()
            }
        }
    }

    private func prepareStoreIfNeeded() async {
        if storeHolder.store == nil {
            storeHolder.store = WaterControlStore(modelContext: modelContext)
        }
    }

    private func reloadLocalStore() async {
        await prepareStoreIfNeeded()
        storeHolder.store?.loadFromLocal()
    }

    private func pinnedGroup(in store: WaterControlStore) -> WaterControlGroup? {
        guard !pinnedGroupId.isEmpty else { return nil }
        return store.group(id: pinnedGroupId)
    }
}

private struct PinnedServiceCardLayout<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.callout)
                    .bold()
                    .foregroundColor(color)
                Spacer()
            }

            Spacer(minLength: 6)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 4)
    }
}

@available(iOS 17.0, *)
private struct CampusCardPinnedMiniChart: View {
    let points: [CampusCardMiniChartPoint]

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("时间", point.date),
                y: .value("消费", point.amount)
            )
            .foregroundStyle(.orange)

            AreaMark(
                x: .value("时间", point.date),
                y: .value("消费", point.amount)
            )
            .foregroundStyle(.orange.opacity(0.14))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

private struct CampusCardMiniChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let amount: Double
}

/// 仅用于在 NavigationLink 中拿到 modelContext。
private struct ActivityListPageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        ActivityListPage(modelContext: modelContext)
    }
}

private struct CampusCardPageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        CampusCardPage(modelContext: modelContext)
    }
}

private struct ExamSchedulePageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        ExamSchedulePage(modelContext: modelContext)
    }
}

private struct GradeReportPageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        GradeReportPage(modelContext: modelContext)
    }
}

private struct LibrarySpacePageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        LibrarySpacePage(modelContext: modelContext)
    }
}

private struct WaterControlPageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        WaterControlPage(modelContext: modelContext)
    }
}

@MainActor
private final class CampusCardStoreHolder: ObservableObject {
    @Published var store: YikatongStore?
}

@MainActor
private final class ExamScheduleStoreHolder: ObservableObject {
    @Published var store: ExamScheduleStore?
}

@MainActor
private final class GradeStoreHolder: ObservableObject {
    @Published var store: GradeStore?
}

@MainActor
private final class LibrarySpaceStoreHolder: ObservableObject {
    @Published var store: LibrarySpaceStore?
}

@MainActor
private final class WaterControlStoreHolder: ObservableObject {
    @Published var store: WaterControlStore?
}

private extension LibrarySpaceLibrary {
    var shortDisplayName: String {
        name
            .replacingOccurrences(of: "校区图书馆", with: "")
            .replacingOccurrences(of: "图书馆", with: "")
            .replacingOccurrences(of: "校区", with: "")
    }
}
