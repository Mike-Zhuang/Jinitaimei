import SwiftUI
import TongjiKit
import WebKit
import UIKit

/// 教学管理信息系统通知公告列表。
public struct TeachingNoticePage: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @State private var notices: [TeachingNotice] = []
    @State private var page = 1
    @State private var total = 0
    @State private var isLoading = false
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        List {
            if !campusModel.loggedIn {
                ContentUnavailableView(
                    "请先登录校园账户",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("进入“设置 → 校园账户”完成登录后可查看通知公告")
                )
            } else {
                ForEach(notices) { notice in
                    NavigationLink {
                        TeachingNoticeDetailPage(notice: notice)
                    } label: {
                        TeachingNoticeRow(notice: notice)
                    }
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
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("教学管理信息系统通知公告")
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        Group {
            if let detail {
                TeachingNoticeHTMLView(html: wrappedHTML(detail.contentHTML))
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if isLoading {
                ProgressView("正在加载通知正文…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "正文加载失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                EmptyView()
            }
        }
        .navigationTitle(notice.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard detail == nil, !isLoading else { return }
            await loadDetail()
        }
        .toolbar {
            if detail == nil && !isLoading {
                Button("重试") {
                    Task { await loadDetail() }
                }
            }
        }
    }

    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await TeachingNoticeAPI().fetchNoticeDetail(id: notice.id)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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

private struct TeachingNoticeHTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.alwaysBounceVertical = true
        webView.loadHTMLString(html, baseURL: URL(string: "https://1.tongji.edu.cn"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
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
    }
}
