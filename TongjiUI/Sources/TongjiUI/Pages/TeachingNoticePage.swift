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
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        Group {
            if let detail {
                if detail.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && detail.attachments.isEmpty {
                    ContentUnavailableView(
                        "正文为空",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("接口已返回详情，但没有正文内容")
                    )
                } else {
                    detailContent(for: detail)
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
        .fullScreenCover(item: $previewItem) { item in
            TeachingNoticeQuickLookPreview(url: item.url) {
                previewItem = nil
            }
            .ignoresSafeArea()
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

    /// 单一垂直滚动流：头部信息 → 正文（自适应高度，内部滚动关闭）→ 附件区。
    @ViewBuilder
    private func detailContent(for detail: TeachingNoticeDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(for: detail)

                if !detail.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TeachingNoticeHTMLView(html: wrappedHTML(detail.contentHTML), height: $contentHeight)
                        .frame(height: contentHeight)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }

                if !detail.attachments.isEmpty {
                    TeachingNoticeAttachmentSection(
                        attachments: detail.attachments,
                        states: attachmentStates,
                        onTap: { attachment in
                            Task { await handleAttachmentTap(attachment) }
                        }
                    )
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 12)
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func detailHeader(for detail: TeachingNoticeDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if let createUser = detail.createUser?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !createUser.isEmpty {
                    Label(createUser, systemImage: "person.crop.circle")
                        .lineLimit(1)
                }
                Label(detail.displayDate, systemImage: "clock")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
                .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
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
            let loaded = try await TeachingNoticeAPI().fetchNoticeDetail(id: notice.id)
            detail = loaded
            restoreDownloadedStates(for: loaded.attachments)
            print(
                "[TeachingNotice] 页面准备渲染 id=\(notice.id) htmlLen=\(loaded.contentHTML.count) attachments=\(loaded.attachments.count)"
            )
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            print("[TeachingNotice] 正文加载失败 id=\(notice.id): \(error)")
        }
    }

    /// 根据本地缓存恢复「已下载」状态：详情页重新进入时不再显示成未下载、避免重复下载。
    private func restoreDownloadedStates(for attachments: [TeachingNoticeAttachment]) {
        let api = TeachingNoticeAPI()
        for attachment in attachments {
            if case .downloaded = attachmentStates[attachment.id] { continue }
            if let cached = api.cachedAttachmentURL(for: attachment) {
                attachmentStates[attachment.id] = .downloaded(cached)
            }
        }
    }

    @MainActor
    private func handleAttachmentTap(_ attachment: TeachingNoticeAttachment) async {
        if case .downloaded(let url) = attachmentStates[attachment.id],
           FileManager.default.fileExists(atPath: url.path) {
            previewItem = TeachingNoticePreviewItem(url: url)
            return
        }
        if case .downloading = attachmentStates[attachment.id] {
            return
        }
        // 缓存命中：直接预览，不重复下载。
        if let cached = TeachingNoticeAPI().cachedAttachmentURL(for: attachment) {
            attachmentStates[attachment.id] = .downloaded(cached)
            previewItem = TeachingNoticePreviewItem(url: cached)
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
        :root {
            color-scheme: light dark;
        }
        body {
            /* 上下留白交给外层 SwiftUI 间距，避免与头部/附件区重复留白。 */
            margin: 0 18px;
            min-width: 100%;
            color: #111111;
            font: -apple-system-body;
            line-height: 1.55;
            word-break: break-word;
            overflow-wrap: anywhere;
            overflow-x: auto;
        }
        @media (prefers-color-scheme: dark) {
            body {
                color: #F2F2F7;
            }
        }
        img {
            height: auto;
        }
        table, pre, img {
            max-width: none;
        }
        table {
            border-collapse: collapse;
            width: max-content;
        }
        pre {
            white-space: pre;
            overflow-x: auto;
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
        // 不再内嵌 ScrollView / 固定高度：附件行内联平铺，与正文共享外层同一滚动流。
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("附件")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("\(attachments.count)")
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 6)

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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if attachment.id != attachments.last?.id {
                    Divider()
                        .padding(.leading, 58)
                }
            }
        }
        .background(Color(.systemBackground))
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

private struct TeachingNoticePreviewItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

/// 附件预览。
///
/// 用一个宿主 `UIViewController` 原生 `present` 出 `QLPreviewController`，
/// 这是拿到 QuickLook 完整原生 chrome（完成 + 分享 + 铅笔标注）的唯一可靠方式
/// ——若把 QLPreviewController 直接塞进 SwiftUI 的 representable，这些按钮不会出现。
///
/// 再用 `isModalInPresentation = true` 关掉 QuickLook 的下滑关闭手势：
/// 顶部轻轻下滑只会滚动/缩放文档，退出只能点左上角「完成」。
private struct TeachingNoticeQuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> QuickLookHostController {
        let host = QuickLookHostController()
        host.url = url
        host.onDismiss = onDismiss
        return host
    }

    func updateUIViewController(_ controller: QuickLookHostController, context: Context) {
        controller.url = url
    }
}

/// 负责在自身出现后原生弹出 QLPreviewController 的宿主控制器。
private final class QuickLookHostController: UIViewController,
    QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    var url: URL?
    var onDismiss: (() -> Void)?
    private var hasPresented = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasPresented, url != nil else { return }
        hasPresented = true

        let preview = QLPreviewController()
        preview.dataSource = self
        preview.delegate = self
        // 禁用下滑关闭，避免轻轻一滑误退出；退出走 QuickLook 自带的「完成」按钮。
        preview.isModalInPresentation = true
        preview.modalPresentationStyle = .fullScreen
        present(preview, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        url == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/dev/null")) as NSURL
    }

    /// 允许标注/编辑：直接把改动写回原文件，这样标注完仍可分享同一份（含标注）文件。
    func previewController(
        _ controller: QLPreviewController,
        editingModeFor previewItem: QLPreviewItem
    ) -> QLPreviewItemEditingMode {
        .updateContents
    }

    func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: QLPreviewItem) {
        print("[TeachingNotice] 附件标注已写回原文件")
    }

    /// QuickLook 自身的「完成」关闭后，连带收起 SwiftUI 的 fullScreenCover。
    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        onDismiss?()
    }
}

/// 自适应高度的正文 WebView。
///
/// 关闭 WKWebView 自身滚动，把渲染后的内容高度经 `height` 回传给 SwiftUI，
/// 让它作为普通子视图嵌入外层统一的 `ScrollView`，从而实现「正文 + 附件」
/// 单一滚动流。
private struct TeachingNoticeHTMLView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        // WebView 允许横向滚动以容纳宽表格；纵向高度仍由 contentSize 回传给外层 ScrollView。
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = true
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.bounces = false
        webView.scrollView.isDirectionalLockEnabled = true
        context.coordinator.observeContentSize(of: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        print("[TeachingNotice] WebView loadHTML len=\(html.count)")
        webView.loadHTMLString(html, baseURL: URL(string: "https://1.tongji.edu.cn"))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving(webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        private let height: Binding<CGFloat>
        private var observation: NSKeyValueObservation?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        /// 观察 contentSize：图片等资源异步加载完成后高度会变化，需要持续同步。
        func observeContentSize(of webView: WKWebView) {
            observation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                self?.updateHeight(scrollView.contentSize.height)
            }
        }

        func stopObserving(_ webView: WKWebView) {
            observation?.invalidate()
            observation = nil
        }

        private func updateHeight(_ newHeight: CGFloat) {
            let resolved = max(newHeight, 1)
            guard abs(height.wrappedValue - resolved) > 0.5 else { return }
            DispatchQueue.main.async { [height] in
                height.wrappedValue = resolved
            }
        }

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
            // 兜底：首帧 contentSize 可能滞后，加载完成后主动再测一次真实文档高度。
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
                if let number = value as? CGFloat {
                    self?.updateHeight(number)
                } else if let number = value as? Double {
                    self?.updateHeight(CGFloat(number))
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[TeachingNotice] WebView didFail: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[TeachingNotice] WebView didFailProvisional: \(error)")
        }
    }
}
