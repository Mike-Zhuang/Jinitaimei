import SwiftUI
import SwiftData
import SafariServices
import TongjiKit

/// 卓越星活动列表页。
///
/// 形态参考 DanXi-swift `FudanUI/Pages/AnnouncementPage.swift` 的"可点开列表"：
/// 列表项 → Safari 详情。
public struct ActivityListPage: View {

    @StateObject private var store: ActivityStore
    @State private var presentedURL: IdentifiedURL?

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: ActivityStore(modelContext: modelContext))
    }

    public var body: some View {
        List {
            ForEach(store.activities, id: \.remoteId) { activity in
                Button {
                    if let link = activity.link, let url = URL(string: link) {
                        presentedURL = IdentifiedURL(url: url)
                    }
                } label: {
                    ActivityRow(activity: activity)
                }
                .buttonStyle(.plain)
            }
            if store.activities.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    "暂无活动",
                    systemImage: "star.circle",
                    description: Text("下拉或点击右上角刷新")
                )
            }
        }
        .listStyle(.plain)
        .navigationTitle("卓越星")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.sync() }
                } label: {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isLoading)
            }
        }
        .refreshable {
            await store.sync()
        }
        .task {
            if store.activities.isEmpty {
                await store.sync()
            }
        }
        .alert("加载失败", isPresented: .constant(store.lastError != nil)) {
            Button("好") {}
        } message: {
            Text(store.lastError ?? "")
        }
        .sheet(item: $presentedURL) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
    }
}

struct ActivityRow: View {
    let activity: CampusActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activity.title)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                if activity.activityDate > Date.distantPast {
                    Text(activity.activityDate.formatted(date: .abbreviated, time: .shortened))
                }
                if let loc = activity.location, !loc.isEmpty {
                    Text("·").foregroundColor(.secondary)
                    Text(loc)
                        .lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if let desc = activity.descriptionText, !desc.isEmpty {
                Text(desc)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// SFSafariViewController 的 SwiftUI 包装，用于打开活动详情。
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
