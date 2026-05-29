import SwiftUI
import TongjiKit
import WebKit
import UIKit
import QuickLook

/// 教学管理信息系统通知公告列表。
public struct TeachingNoticePage: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @State private var notices: [TeachingNotice] = []
    @State private var page = 1
    @State private var total = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedNotice: TeachingNotice?

    public init() {}

    public var body: some View {
        List {
            if !campusModel.loggedIn {
                ContentUnavailableView(
                    "请先登录校园账户",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("进入“设置 → 校园账户”完成登录后可查看通知公告")
                )
                .listEmptyRowStyle()
            } else {
                ForEach(notices) { notice in
                    Button {
                        print("[TeachingNotice] 点击通知 id=\(notice.id) title=\(notice.title)")
                        selectedNotice = notice
                    } label: {
                        TeachingNoticeRow(notice: notice)
                    }
                    .buttonStyle(.plain)
                }

                if isLoading && notices.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if notices.isEmpty && errorMessage == nil {
                    ContentUnavailableView(
                        "暂无通知公告",
                        systemImage: "bell",
                        description: Text("下拉或点击右上角刷新")
                    )
                    .listEmptyRowStyle()
                }

                if hasMore {
                    Button {
                        Task { await loadNextPage() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("加载更多")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLoading)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("教学管理信息系统通知公告")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedNotice) { notice in
            TeachingNoticeDetailPage(notice: notice)
        }
        .toolbar {
            Button {
                Task { await refresh() }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isLoading || !campusModel.loggedIn)
        }
        .refreshable {
            await refresh()
        }
        .task {
            guard campusModel.loggedIn, notices.isEmpty else { return }
            await refresh()
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            if loggedIn {
                Task { await refresh() }
            } else {
                notices = []
                page = 1
                total = 0
                errorMessage = nil
            }
        }
        .alert("加载失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var hasMore: Bool {
        notices.count < total
    }

    private func refresh() async {
        await load(pageToLoad: 1, replacing: true)
    }

    private func loadNextPage() async {
        guard hasMore else { return }
        await load(pageToLoad: page + 1, replacing: false)
    }

    private func load(pageToLoad: Int, replacing: Bool) async {
        guard campusModel.loggedIn, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await TeachingNoticeAPI().fetchNotices(page: pageToLoad)
            page = result.page
            total = result.total
            if replacing {
                notices = TeachingNotice.sortedForList(result.notices)
            } else {
                let merged = notices + result.notices.filter { incoming in
                    !notices.contains { $0.id == incoming.id }
                }
                notices = TeachingNotice.sortedForList(merged)
            }
            if replacing {
                await CampusNotificationDetector.shared.processTeachingNotices(notices)
            }
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}

private struct TeachingNoticeRow: View {
    let notice: TeachingNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if notice.isPinned {
                    Text("置顶")
                        .font(.caption2)
                        .bold()
                        .foregroundColor(.orange)
                }
                Text(notice.title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(3)
            }

            Text(notice.displayDate)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct TeachingNoticeDetailPage: View {
    let notice: TeachingNotice
    @State private var detail: TeachingNoticeDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didAppear = false
    @State private var attachmentStates: [Int: AttachmentDownloadState] = [:]
    @State private var previewItem: TeachingNoticePreviewItem?

    var body: some View {
        Group {
            if let detail {
                if detail.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "正文为空",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("接口已返回详情，但没有正文内容")
                    )
                } else {
                    VStack(spacing: 0) {
                        TeachingNoticeHTMLView(html: wrappedHTML(detail.contentHTML))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.systemBackground))

                        if !detail.attachments.isEmpty {
                            Divider()
                            TeachingNoticeAttachmentSection(
                                attachments: detail.attachments,
                                states: attachmentStates,
                                onTap: { attachment in
                                    Task { await handleAttachmentTap(attachment) }
                                }
                            )
                        }
                    }
                }
            } else if isLoading {
                ProgressView("正在加载通知正文…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "正文加载失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("正在准备加载通知正文…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationTitle(notice.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $previewItem) { item in
            TeachingNoticeQuickLookPreview(url: item.url)
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            print("[TeachingNotice] 详情页出现 id=\(notice.id)")
            Task { await loadDetailIfNeeded(trigger: "onAppear") }
        }
        .task(id: notice.id) {
            await loadDetailIfNeeded(trigger: "task")
        }
        .toolbar {
            if detail == nil && !isLoading {
                Button("重试") {
                    Task { await loadDetail(force: true, trigger: "retry") }
                }
            }
        }
    }

    private func loadDetailIfNeeded(trigger: String) async {
        guard detail == nil, !isLoading else { return }
        await loadDetail(force: false, trigger: trigger)
    }

    private func loadDetail(force: Bool, trigger: String) async {
        if force {
            detail = nil
            errorMessage = nil
        }
        guard detail == nil, !isLoading else { return }
        print("[TeachingNotice] 开始加载详情 trigger=\(trigger) id=\(notice.id)")
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await TeachingNoticeAPI().fetchNoticeDetail(id: notice.id)
            print(
                "[TeachingNotice] 页面准备渲染 id=\(notice.id) htmlLen=\(detail?.contentHTML.count ?? 0) attachments=\(detail?.attachments.count ?? 0)"
            )
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            print("[TeachingNotice] 正文加载失败 id=\(notice.id): \(error)")
        }
    }

    @MainActor
    private func handleAttachmentTap(_ attachment: TeachingNoticeAttachment) async {
        if case .downloaded(let url) = attachmentStates[attachment.id] {
            previewItem = TeachingNoticePreviewItem(url: url)
            return
        }
        if case .downloading = attachmentStates[attachment.id] {
            return
        }

        attachmentStates[attachment.id] = .downloading
        do {
            let url = try await TeachingNoticeAPI().downloadAttachment(attachment)
            attachmentStates[attachment.id] = .downloaded(url)
            previewItem = TeachingNoticePreviewItem(url: url)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "附件下载失败，请重试"
            attachmentStates[attachment.id] = .failed(message)
            print("[TeachingNotice] 附件下载失败 id=\(attachment.id) file=\(attachment.fileName): \(error)")
        }
    }

    private func wrappedHTML(_ body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">
        <style>
        body {
            margin: 18px;
            color: #111111;
            font: -apple-system-body;
            line-height: 1.55;
            word-break: break-word;
            overflow-wrap: anywhere;
        }
        img, table {
            max-width: 100%;
            height: auto;
        }
        table {
            border-collapse: collapse;
        }
        a {
            color: #0A84FF;
        }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

private enum AttachmentDownloadState: Equatable {
    case idle
    case downloading
    case downloaded(URL)
    case failed(String)
}

private struct TeachingNoticeAttachmentSection: View {
    let attachments: [TeachingNoticeAttachment]
    let states: [Int: AttachmentDownloadState]
    let onTap: (TeachingNoticeAttachment) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("附件")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(attachments) { attachment in
                    Button {
                        onTap(attachment)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(attachment.fileName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if case .failed(let message) = states[attachment.id] ?? .idle {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 8)

                            trailingView(for: states[attachment.id] ?? .idle)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    if attachment.id != attachments.last?.id {
                        Divider()
                            .padding(.leading, 58)
                    }
                }

                Color.clear
                    .frame(height: 10)
            }
        }
        .scrollIndicators(.visible)
        .frame(height: min(attachmentPreferredHeight, attachmentHeightLimit))
        .background(Color(.systemBackground))
    }

    private var attachmentPreferredHeight: CGFloat {
        let headerHeight: CGFloat = 42
        let rowHeight: CGFloat = 72
        let bottomPadding: CGFloat = 10
        return min(220, headerHeight + rowHeight * CGFloat(attachments.count) + bottomPadding)
    }

    private var attachmentHeightLimit: CGFloat {
        min(220, UIScreen.main.bounds.height * 0.3)
    }

    @ViewBuilder
    private func trailingView(for state: AttachmentDownloadState) -> some View {
        switch state {
        case .idle:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView()
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
        }
    }
}

private struct TeachingNoticePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct TeachingNoticeQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct TeachingNoticeHTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.alwaysBounceVertical = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        print("[TeachingNotice] WebView loadHTML len=\(html.count)")
        webView.loadHTMLString(html, baseURL: URL(string: "https://1.tongji.edu.cn"))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[TeachingNotice] WebView didFinish url=\(webView.url?.absoluteString ?? "about:blank")")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[TeachingNotice] WebView didFail: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[TeachingNotice] WebView didFailProvisional: \(error)")
        }
    }
}
