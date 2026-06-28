import Foundation
import SwiftData
import SwiftUI
import TongjiKit

public struct LibrarySpacePage: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var store: LibrarySpaceStore
    @State private var selectedLibrary: LibrarySpaceLibrary?
    @State private var selectedTab: LibrarySpaceTab = .seats
    @State private var overviewSingleSeatOnly = false
    @State private var singleSeatStats: [String: SingleSeatAreaStats] = [:]
    @State private var isScanningSingleSeat = false

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: LibrarySpaceStore(modelContext: modelContext))
    }

    public var body: some View {
        List {
            if !campusModel.loggedIn {
                ContentUnavailableView(
                    "请先登录校园账户",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("登录后可查看图书馆座位状态。")
                )
                .listEmptyRowStyle()
            } else {
                overviewSection

                if !store.targetLibraries.isEmpty {
                    Section {
                        Picker("图书馆", selection: selectedLibraryBinding) {
                            ForEach(store.targetLibraries) { library in
                                Text(library.shortDisplayName).tag(library)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("视图", selection: $selectedTab) {
                            ForEach(LibrarySpaceTab.allCases) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if let selectedLibrary {
                        switch selectedTab {
                        case .seats:
                            seatSections(for: selectedLibrary)
                        case .rooms:
                            seminarSections(for: selectedLibrary)
                        }
                    }
                } else if !store.isLoading {
                    ContentUnavailableView("暂无图书馆数据", systemImage: "chair.lounge")
                        .listEmptyRowStyle()
                }

                if !store.otherLibraries.isEmpty {
                    Section("其他空间") {
                        ForEach(store.otherLibraries) { library in
                            LibraryOverviewRow(library: library, compact: true)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("图书馆座位")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            guard campusModel.loggedIn else { return }
            await syncAndSelectLibrary()
        }
        .task {
            guard campusModel.loggedIn else { return }
            if store.libraries.isEmpty {
                await syncAndSelectLibrary()
            } else {
                selectDefaultLibraryIfNeeded()
            }
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            if !loggedIn {
                store.clearLocalData()
                selectedLibrary = nil
            }
        }
        .onChange(of: store.targetLibraries) { _, _ in
            selectDefaultLibraryIfNeeded()
        }
        .alert("加载失败", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("好") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var selectedLibraryBinding: Binding<LibrarySpaceLibrary> {
        Binding {
            selectedLibrary ?? store.targetLibraries.first!
        } set: { library in
            selectedLibrary = library
        }
    }

    @ViewBuilder
    private var overviewSection: some View {
        Section {
            if store.isLoading, store.libraries.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在同步图书馆座位状态")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("座位占用概览")
                                .font(.headline)
                        }
                        Spacer()
                        if store.isLoading {
                            ProgressView()
                        }
                    }

                    ForEach(store.targetLibraries) { library in
                        LibraryOverviewRow(library: library)
                    }

                    if let lastSync = store.lastSyncTime {
                        Text("同步于 \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder
    private func seatSections(for library: LibrarySpaceLibrary) -> some View {
        let areas = store.areas(in: library)
        if areas.isEmpty {
            ContentUnavailableView("暂无座位区域", systemImage: "square.grid.3x3")
                .listEmptyRowStyle()
        } else {
            Section("筛选") {
                Toggle("只看单人单座", isOn: $overviewSingleSeatOnly)
                if overviewSingleSeatOnly && isScanningSingleSeat {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在识别各区域单人单座")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: "\(library.id)-\(overviewSingleSeatOnly)-\(areas.count)") {
                await scanSingleSeatStatsIfNeeded(areas: areas)
            }

            let visibleAreas = visibleSeatAreas(areas)
            if visibleAreas.isEmpty {
                ContentUnavailableView("没有单人单座区域", systemImage: "chair")
                    .listEmptyRowStyle()
            } else {
                ForEach(groupAreasByFloor(visibleAreas), id: \.floor) { group in
                    Section(group.floor) {
                        ForEach(group.areas, id: \.navigationIdentity) { area in
                            NavigationLink {
                                LibrarySeatAreaPage(
                                    area: area,
                                    initialSingleSeatOnly: overviewSingleSeatOnly
                                )
                                    .id(area.navigationIdentity)
                            } label: {
                                LibraryAreaRow(
                                    area: area,
                                    singleSeatStats: singleSeatStats[area.navigationIdentity],
                                    isSingleSeatScanning: overviewSingleSeatOnly &&
                                        LibrarySeatLocalTagger.areaMayContainSingleSeat(area) &&
                                        singleSeatStats[area.navigationIdentity] == nil
                                )
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func seminarSections(for library: LibrarySpaceLibrary) -> some View {
        let rooms = store.rooms(in: library)
        if rooms.isEmpty {
            ContentUnavailableView("暂无研习室数据", systemImage: "person.3.sequence")
                .listEmptyRowStyle()
        } else {
            Section("研习室") {
                LibrarySeminarRoomList(rooms: rooms)
            }
        }
    }

    private func syncAndSelectLibrary() async {
        await store.sync(force: true)
        selectDefaultLibraryIfNeeded()
    }

    private func selectDefaultLibraryIfNeeded() {
        guard !store.targetLibraries.isEmpty else { return }
        if let selectedLibrary, store.targetLibraries.contains(selectedLibrary) {
            return
        }
        selectedLibrary = store.targetLibraries.first
    }

    private func groupAreasByFloor(_ areas: [LibrarySpaceArea]) -> [(floor: String, areas: [LibrarySpaceArea])] {
        var result: [(floor: String, areas: [LibrarySpaceArea])] = []
        for area in areas {
            let floor = area.floorName.isEmpty ? "区域" : area.floorName
            if let index = result.firstIndex(where: { $0.floor == floor }) {
                result[index].areas.append(area)
            } else {
                result.append((floor: floor, areas: [area]))
            }
        }
        return result
    }

    private func visibleSeatAreas(_ areas: [LibrarySpaceArea]) -> [LibrarySpaceArea] {
        guard overviewSingleSeatOnly else { return areas }
        return areas.filter { area in
            guard LibrarySeatLocalTagger.areaMayContainSingleSeat(area) else { return false }
            guard let stats = singleSeatStats[area.navigationIdentity] else {
                return true
            }
            return stats.total > 0
        }
    }

    @MainActor
    private func scanSingleSeatStatsIfNeeded(areas: [LibrarySpaceArea]) async {
        guard overviewSingleSeatOnly else { return }
        let candidates = areas.filter(LibrarySeatLocalTagger.areaMayContainSingleSeat)
        let missing = candidates.filter { singleSeatStats[$0.navigationIdentity] == nil }
        guard !missing.isEmpty else { return }

        isScanningSingleSeat = true
        defer { isScanningSingleSeat = false }

        var index = 0
        while index < missing.count {
            let batch = Array(missing[index..<min(index + 2, missing.count)])
            await withTaskGroup(of: (String, SingleSeatAreaStats).self) { group in
                for area in batch {
                    group.addTask {
                        do {
                            let detail = try await LibrarySpaceAPI().fetchSeatAreaDetail(area: area)
                            let singleSeats = detail.seats.filter {
                                $0.labels.contains(LibrarySpaceConstants.localSingleSeatTag)
                            }
                            let stats = SingleSeatAreaStats(
                                free: singleSeats.filter(\.isFree).count,
                                total: singleSeats.count,
                                failed: false
                            )
                            return (area.navigationIdentity, stats)
                        } catch {
                            return (area.navigationIdentity, SingleSeatAreaStats(free: 0, total: 0, failed: true))
                        }
                    }
                }
                for await (identity, stats) in group {
                    singleSeatStats[identity] = stats
                }
            }
            index += 2
        }
    }
}

private enum LibrarySpaceTab: String, CaseIterable, Identifiable {
    case seats
    case rooms

    var id: String { rawValue }
    var title: String {
        switch self {
        case .seats: "座位"
        case .rooms: "研习室"
        }
    }
}

private struct LibraryOverviewRow: View {
    let library: LibrarySpaceLibrary
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(library.name)
                    .font(compact ? .subheadline : .callout)
                    .fontWeight(compact ? .regular : .semibold)
                Text("可用 \(library.freeSeats) / 总座位 \(library.totalSeats)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            CircularOccupancyView(value: library.usedSeats, total: library.totalSeats)
                .frame(width: compact ? 38 : 46, height: compact ? 38 : 46)
        }
    }
}

private struct CircularOccupancyView: View {
    let value: Int
    let total: Int

    private var ratio: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(value) / Double(total), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.18), lineWidth: 6)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(ratio > 0.8 ? .red : .blue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(ratio * 100))%")
                .font(.caption2)
                .bold()
        }
    }
}

private struct LibraryAreaRow: View {
    let area: LibrarySpaceArea
    var singleSeatStats: SingleSeatAreaStats?
    var isSingleSeatScanning = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(area.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("可用 \(area.freeSeats) / \(area.totalSeats)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let singleSeatStats {
                    Text(singleSeatStats.failed ? "单人单座识别失败" : "单人单座 可用 \(singleSeatStats.free) / \(singleSeatStats.total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if isSingleSeatScanning {
                    Text("正在识别单人单座")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ProgressView(value: area.freeRatio)
                .frame(width: 72)
        }
    }
}

private struct SingleSeatAreaStats: Equatable, Sendable {
    let free: Int
    let total: Int
    let failed: Bool
}

private struct LibrarySeatAreaPage: View {
    let area: LibrarySpaceArea
    @State private var detail: LibrarySeatAreaDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var statusFilter: SeatStatusFilter = .all
    @State private var singleSeatOnly = false

    private let api = LibrarySpaceAPI()

    init(area: LibrarySpaceArea, initialSingleSeatOnly: Bool = false) {
        self.area = area
        _singleSeatOnly = State(initialValue: initialSingleSeatOnly)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(area.mergedName)
                        .font(.headline)
                    Text("可用 \(area.freeSeats) / \(area.totalSeats)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let detail {
                filterSection(detail: detail)
                Section {
                    LibrarySeatMapView(seats: filteredSeats(from: detail.seats))
                        .frame(height: 520)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                } footer: {
                    Text("座位图按学校返回坐标绘制；筛选只影响高亮范围，不提交预约。")
                }
            } else if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载座位图")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let errorMessage {
                Section {
                    ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(area.mergedName.isEmpty ? area.name : area.mergedName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load(force: true)
        }
        .task {
            await load(force: false)
        }
    }

    @ViewBuilder
    private func filterSection(detail: LibrarySeatAreaDetail) -> some View {
        Section("筛选") {
            Picker("状态", selection: $statusFilter) {
                ForEach(SeatStatusFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            Toggle("只看单人单座", isOn: $singleSeatOnly)
        }
    }

    private func load(force: Bool) async {
        guard !isLoading else { return }
        if detail != nil, !force { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            detail = try await api.fetchSeatAreaDetail(area: area)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "座位图加载失败"
        }
    }

    private func filteredSeats(from seats: [LibrarySeat]) -> [LibrarySeat] {
        seats.filter { seat in
            statusFilter.matches(seat) &&
            (!singleSeatOnly || seat.labels.contains(LibrarySpaceConstants.localSingleSeatTag))
        }
    }
}

private enum SeatStatusFilter: String, CaseIterable, Identifiable {
    case all
    case free
    case occupied

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .free: "空闲"
        case .occupied: "占用"
        }
    }

    func matches(_ seat: LibrarySeat) -> Bool {
        switch self {
        case .all: true
        case .free: seat.isFree
        case .occupied: !seat.isFree
        }
    }
}

private struct LibrarySeatMapView: View {
    let seats: [LibrarySeat]

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.07))
                    .frame(width: 860, height: 860)

                ForEach(seats) { seat in
                    SeatRect(seat: seat)
                        .position(x: seat.x * 8.2 + 24, y: seat.y * 8.2 + 24)
                }
            }
            .frame(width: 900, height: 900)
            .padding(10)
        }
    }
}

private struct SeatRect: View {
    let seat: LibrarySeat

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(seat.isFree ? Color.green.opacity(0.72) : Color.secondary.opacity(0.45))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(seat.labels.contains(LibrarySpaceConstants.localSingleSeatTag) ? Color.orange : Color.clear, lineWidth: 2)
            }
            .frame(width: max(seat.width * 8.2, 13), height: max(seat.height * 8.2, 13))
            .overlay {
                if seat.width > 2.8 || seat.height > 2.8 {
                    Text(seat.number)
                        .font(.system(size: 6))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.4)
                }
            }
            .accessibilityLabel("\(seat.number)，\(seat.statusName)")
    }
}

private struct LibrarySeminarRoomList: View {
    let rooms: [LibrarySpaceRoom]
    @State private var selectedDay = 0
    @State private var peopleFilter: SeminarPeopleFilter = .all

    var body: some View {
        VStack(spacing: 12) {
            Picker("日期", selection: $selectedDay) {
                Text("今天").tag(0)
                Text("明天").tag(1)
                Text("后天").tag(2)
            }
            .pickerStyle(.segmented)

            Picker("人数", selection: $peopleFilter) {
                ForEach(SeminarPeopleFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)

            ForEach(rooms) { room in
                LibrarySeminarRoomRow(
                    room: room,
                    selectedDay: selectedDay,
                    peopleFilter: peopleFilter
                )
            }
        }
        .padding(.vertical, 4)
    }
}

private enum SeminarPeopleFilter: String, CaseIterable, Identifiable {
    case all
    case one
    case two
    case three
    case four
    case five
    case sixPlus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "不限人数"
        case .one: "1人"
        case .two: "2人"
        case .three: "3人"
        case .four: "4人"
        case .five: "5人"
        case .sixPlus: "6人及以上"
        }
    }

    func matches(_ detail: LibrarySeminarRoomDetail) -> Bool {
        guard let selected = selectedPeople else { return true }
        guard let range = peopleRange(detail) else {
            return false
        }
        switch self {
        case .sixPlus:
            return range.upperBound >= 6
        default:
            return range.contains(selected)
        }
    }

    private var selectedPeople: Int? {
        switch self {
        case .all: nil
        case .one: 1
        case .two: 2
        case .three: 3
        case .four: 4
        case .five: 5
        case .sixPlus: 6
        }
    }

    private func peopleRange(_ detail: LibrarySeminarRoomDetail) -> ClosedRange<Int>? {
        if detail.minPeople > 0, detail.maxPeople > 0 {
            return min(detail.minPeople, detail.maxPeople)...max(detail.minPeople, detail.maxPeople)
        }
        if let availability = detail.availabilities.first,
           availability.minPeople > 0,
           availability.maxPeople > 0 {
            return min(availability.minPeople, availability.maxPeople)...max(availability.minPeople, availability.maxPeople)
        }
        return Self.peopleRange(from: detail.memberCountText)
    }

    private static func peopleRange(from text: String) -> ClosedRange<Int>? {
        let pattern = #"(\d+)\s*[-~至]\s*(\d+)\s*人?|(\d+)\s*人?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func value(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return Int(text[swiftRange])
        }
        if let start = value(1), let end = value(2) {
            return min(start, end)...max(start, end)
        }
        if let single = value(3) {
            return single...single
        }
        return nil
    }
}

private struct LibrarySeminarRoomRow: View {
    let room: LibrarySpaceRoom
    let selectedDay: Int
    let peopleFilter: SeminarPeopleFilter
    @State private var detail: LibrarySeminarRoomDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let api = LibrarySpaceAPI()

    var body: some View {
        Group {
            if shouldShow {
                content
            }
        }
        .task {
            await load()
        }
    }

    private var shouldShow: Bool {
        guard let detail else {
            return true
        }
        return peopleFilter.matches(detail)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(room.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(room.floorName.isEmpty ? room.typeName : "\(room.floorName) · \(room.typeName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let detail {
                    Text(peopleText(detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let availability = detail?.availabilities[safe: selectedDay] {
                LibrarySeminarTimeline(availability: availability)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("正在加载空闲时段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await api.fetchSeminarRoomDetail(room: room)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "时段加载失败"
        }
    }

    private func peopleText(_ detail: LibrarySeminarRoomDetail) -> String {
        if detail.minPeople > 0, detail.maxPeople > 0 {
            return "\(detail.minPeople)-\(detail.maxPeople)人"
        }
        return detail.memberCountText.isEmpty ? "人数未标注" : "\(detail.memberCountText)人"
    }
}

private struct LibrarySeminarTimeline: View {
    let availability: LibrarySeminarRoomAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.14))

                    ForEach(availability.freeSegments) { segment in
                        let range = max(availability.openEndMinute - availability.openStartMinute, 1)
                        let start = CGFloat(segment.beginMinute - availability.openStartMinute) / CGFloat(range)
                        let width = CGFloat(segment.endMinute - segment.beginMinute) / CGFloat(range)
                        Capsule()
                            .fill(Color.green.opacity(0.75))
                            .frame(width: max(proxy.size.width * width, 3))
                            .offset(x: proxy.size.width * start)
                    }
                }
            }
            .frame(height: 12)

            if availability.freeSegments.isEmpty {
                Text("暂无空闲时段")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(availability.freeSegments.map { "\($0.beginText)-\($0.endText)" }.joined(separator: "  "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private extension LibrarySpaceLibrary {
    var shortDisplayName: String {
        name
            .replacingOccurrences(of: "校区图书馆", with: "")
            .replacingOccurrences(of: "图书馆", with: "")
            .replacingOccurrences(of: "校区", with: "")
    }
}

private extension LibrarySpaceArea {
    var navigationIdentity: String {
        [libraryId, floorId, id, mergedName, name].joined(separator: "|")
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
