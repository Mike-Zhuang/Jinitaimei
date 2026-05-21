import SwiftUI
import SwiftData
import TongjiKit

/// 校园服务首页（精简版）。
///
/// 复旦 DanXi-swift 的 `CampusHome` 罗列了图书馆、食堂、巴士、电费、教务通知等
/// 十余个服务入口，并支持置顶服务卡片；此处保留可扩展结构，v1 只有卓越星。
public struct CampusHome: View {

    @StateObject private var model = CampusHomeModel()
    @State private var showEditor = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if !model.pinnedServices.isEmpty {
                    ForEach(model.pinnedServices) { service in
                        Section {
                            NavigationLink {
                                service.destination
                            } label: {
                                service.card
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
            .listStyle(.insetGrouped)
            .navigationTitle("校园服务")
            .toolbar {
                Button("编辑") {
                    showEditor = true
                }
            }
            .sheet(isPresented: $showEditor) {
                CampusHomeEditor(model: model)
            }
        }
    }
}

private enum CampusService: String, CaseIterable, Codable, Identifiable {
    case starActivity

    var id: String { rawValue }

    @ViewBuilder
    var label: some View {
        switch self {
        case .starActivity:
            Label("卓越星活动", systemImage: "star.circle")
        }
    }

    @ViewBuilder
    var card: some View {
        switch self {
        case .starActivity:
            StarActivityCard()
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .starActivity:
            ActivityListPageContainer()
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
        self.unpinnedServices = Self.load(key: unpinnedKey, from: defaults) ?? [.starActivity]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("卓越星", systemImage: "star.circle.fill")
                    .font(.callout)
                    .bold()
                    .foregroundColor(.orange)
                Spacer()
            }

            if let summary = campusModel.starScoreSummary {
                HStack(alignment: .firstTextBaseline) {
                    Text(StarScoreSummary.formatScore(summary.totalScore))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("总星值")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    compactScore("弘", summary.hongwenScore)
                    compactScore("明", summary.mingdeScore)
                    compactScore("矢", summary.shizhiScore)
                    compactScore("求", summary.qiusuoScore)
                    compactScore("力", summary.lixingScore)
                }
            } else {
                Text(campusModel.loggedIntoStar ? "正在等待星值同步" : "登录后同步星值")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task {
            guard campusModel.loggedIntoStar, campusModel.starScoreSummary == nil else { return }
            await campusModel.refreshStarScoreSummary()
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

/// 仅用于在 NavigationLink 中拿到 modelContext。
private struct ActivityListPageContainer: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        ActivityListPage(modelContext: modelContext)
    }
}
