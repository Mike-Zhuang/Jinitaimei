import Charts
import SwiftData
import SwiftUI
import TongjiKit

public struct CampusCardPage: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @StateObject private var store: YikatongStore

    public init(modelContext: ModelContext) {
        _store = StateObject(wrappedValue: YikatongStore(modelContext: modelContext))
    }

    public var body: some View {
        List {
            if !campusModel.loggedIn {
                Section {
                    ContentUnavailableView(
                        "暂无校园卡数据",
                        systemImage: "creditcard.trianglebadge.exclamationmark",
                        description: Text("请先在设置中登录校园账户")
                    )
                    .listEmptyRowStyle(verticalPadding: 44)
                }
            } else if let latest = store.latestSnapshot {
                balanceSection(latest)
                if !chartData.isEmpty {
                    chartSection
                }
                historySection
            } else if store.isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在同步校园卡余额")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "暂无校园卡数据",
                        systemImage: "creditcard",
                        description: Text(store.lastError ?? "下拉刷新后会尝试静默同步余额")
                    )
                    .listEmptyRowStyle(verticalPadding: 44)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("校园卡")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.sync()
        }
        .task {
            guard campusModel.loggedIn, store.latestSnapshot == nil else { return }
            await store.sync()
        }
        .onChange(of: campusModel.loggedIn) { _, loggedIn in
            if !loggedIn {
                store.clearLocalData()
            }
        }
    }

    private func balanceSection(_ snapshot: CampusCardBalanceSnapshot) -> some View {
        Section {
            LabeledContent {
                Text(verbatim: "¥ \(CampusCardFormat.balance(snapshot.balanceYuan))")
                    .font(.title2)
                    .fontWeight(.bold)
                    .privacySensitive()
            } label: {
                Text("校园卡余额")
            }

            if !snapshot.ownerName.isEmpty {
                LabeledContent("持卡人", value: snapshot.ownerName)
                    .font(.footnote)
            }
            if !snapshot.account.isEmpty {
                LabeledContent("账户", value: snapshot.account)
                    .font(.footnote)
            }
            if !snapshot.cardIdentifier.isEmpty {
                LabeledContent("卡号", value: snapshot.cardIdentifier)
                    .font(.footnote)
            }
            LabeledContent("更新时间", value: snapshot.capturedAt.formatted(date: .numeric, time: .shortened))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } footer: {
            Text("当前版本先使用本地多次查询形成的余额快照展示趋势，后续再补消费流水。")
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        if #available(iOS 17.0, *) {
            Section("余额变化") {
                CampusCardBalanceChart(data: chartData)
                    .frame(height: 200)
                    .padding(.top, 8)
            }
        }
    }

    private var historySection: some View {
        Section("最近记录") {
            ForEach(store.snapshots.prefix(20), id: \.capturedAt) { snapshot in
                LabeledContent {
                    Text("¥\(CampusCardFormat.balance(snapshot.balanceYuan))")
                        .fontWeight(.semibold)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.capturedAt.formatted(date: .numeric, time: .shortened))
                        if !snapshot.ownerName.isEmpty {
                            Text(snapshot.ownerName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var chartData: [CampusCardChartPoint] {
        Array(store.snapshots
            .prefix(30)
            .reversed()
            .map { CampusCardChartPoint(date: $0.capturedAt, balance: $0.balanceYuan) })
    }
}

private struct CampusCardChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let balance: Double
}

@available(iOS 17.0, *)
private struct CampusCardBalanceChart: View {
    let data: [CampusCardChartPoint]
    @State private var chartSelection: Date?

    private var displayData: [CampusCardChartPoint] {
        Array(data.suffix(7))
    }

    var body: some View {
        Chart {
            ForEach(displayData) { item in
                LineMark(
                    x: .value("日期", item.date, unit: .day),
                    y: .value("余额", item.balance)
                )
                .foregroundStyle(.blue)

                AreaMark(
                    x: .value("日期", item.date, unit: .day),
                    y: .value("余额", item.balance)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue.opacity(0.18), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            if let chartSelection,
               let selected = displayData.first(where: {
                   Calendar.current.isDate($0.date, inSameDayAs: chartSelection)
               }) {
                RuleMark(x: .value("日期", selected.date, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, spacing: 0) {
                        VStack(spacing: 2) {
                            Text(selected.date.formatted(.dateTime.month().day()))
                                .foregroundStyle(.secondary)
                            Text(verbatim: "¥ \(CampusCardFormat.balance(selected.balance))")
                                .font(.headline)
                        }
                        .fixedSize()
                        .font(.system(.caption, design: .rounded))
                    }
                PointMark(
                    x: .value("日期", selected.date, unit: .day),
                    y: .value("余额", selected.balance)
                )
                .symbolSize(36)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.day(), centered: true)
            }
        }
        .chartYAxisLabel("元")
        .chartXSelection(value: $chartSelection)
    }
}
