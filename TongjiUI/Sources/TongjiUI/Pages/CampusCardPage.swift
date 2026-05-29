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
                if !dailySpendingChartData.isEmpty {
                    chartSection
                }
                transactionSection
            } else if store.isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在同步校园卡余额与消费记录")
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
            await store.sync(force: true)
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

            LabeledContent("更新时间", value: snapshot.capturedAt.formatted(date: .numeric, time: .shortened))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        if #available(iOS 17.0, *) {
            Section("每日消费") {
                CampusCardDailySpendingChart(data: dailySpendingChartData)
                    .frame(height: 200)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var transactionSection: some View {
        Section("最近消费") {
            let validTransactions = store.transactions.filter(\.hasValidTransactionDate)
            let displayTransactions = validTransactions.isEmpty ? store.transactions : validTransactions
            if displayTransactions.isEmpty {
                Text("暂无消费记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayTransactions.prefix(40), id: \.orderId) { transaction in
                    CampusCardTransactionRow(transaction: transaction)
                }
            }
        }
    }

    private var dailySpendingChartData: [CampusCardDailySpendingPoint] {
        let calendar = Calendar.current
        let validTransactions = store.transactions.filter {
            $0.hasValidTransactionDate && $0.signedAmountYuan < 0
        }
        let grouped = Dictionary(grouping: validTransactions) { transaction in
            calendar.startOfDay(for: transaction.transactionDateTime)
        }
        let endDate = calendar.startOfDay(for: validTransactions.first?.transactionDateTime ?? Date())
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 6, to: endDate) else { return nil }
            let total = grouped[date, default: []].reduce(0) { partial, item in
                partial + abs(item.signedAmountYuan)
            }
            return CampusCardDailySpendingPoint(date: date, amount: total)
        }
    }
}

private struct CampusCardDailySpendingPoint: Identifiable {
    let id = UUID()
    let date: Date
    let amount: Double
}

private struct CampusCardTransactionRow: View {
    let transaction: CampusCardTransaction

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: "\(transaction.signSymbol)¥\(CampusCardFormat.balance(abs(transaction.signedAmountYuan)))")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Text("余额 ¥\(CampusCardFormat.balance(transaction.balanceYuan))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.displayLocation)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(transaction.hasValidTransactionDate ? transaction.transactionDateTime.formatted(.dateTime.year().month().day().hour().minute()) : "时间待解析")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !transaction.detailText.isEmpty {
                    Text(transaction.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

@available(iOS 17.0, *)
private struct CampusCardDailySpendingChart: View {
    let data: [CampusCardDailySpendingPoint]
    @State private var chartSelection: Date?

    private var xDomain: ClosedRange<Date> {
        let first = data.first?.date ?? Date()
        let last = data.last?.date ?? first
        let padding: TimeInterval = 12 * 60 * 60
        return first.addingTimeInterval(-padding) ... last.addingTimeInterval(padding)
    }

    private var yDomain: ClosedRange<Double> {
        let maxAmount = data.map(\.amount).max() ?? 0
        let roundedMax = max(20, ceil(maxAmount / 20) * 20)
        return 0 ... roundedMax
    }

    private var axisDates: [Date] {
        data.enumerated().compactMap { index, item in
            index.isMultiple(of: 2) ? item.date : nil
        }
    }

    private var selectedPoint: CampusCardDailySpendingPoint? {
        guard let chartSelection else { return nil }
        return data.min {
            abs($0.date.timeIntervalSince(chartSelection)) <
            abs($1.date.timeIntervalSince(chartSelection))
        }
    }

    var body: some View {
        Chart {
            ForEach(data) { item in
                LineMark(
                    x: .value("日期", item.date, unit: .day),
                    y: .value("消费", item.amount)
                )
                .foregroundStyle(.orange)

                AreaMark(
                    x: .value("日期", item.date, unit: .day),
                    y: .value("消费", item.amount)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange.opacity(0.25), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            if let selected = selectedPoint {
                RuleMark(x: .value("日期", selected.date, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(.secondary)
                    .annotation(
                        position: .top,
                        spacing: 0,
                        overflowResolution: .init(
                            x: .fit(to: .chart),
                            y: .disabled
                        )
                    ) {
                        VStack(spacing: 2) {
                            Text(selected.date.formatted(.dateTime.month().day()))
                                .foregroundStyle(.secondary)
                            Text(verbatim: "¥ \(CampusCardFormat.balance(selected.amount))")
                                .font(.headline)
                        }
                        .fixedSize()
                        .font(.system(.caption, design: .rounded))
                    }
                PointMark(
                    x: .value("日期", selected.date, unit: .day),
                    y: .value("消费", selected.amount)
                )
                .symbolSize(70)
                .foregroundStyle(Color(uiColor: .secondarySystemGroupedBackground))

                PointMark(
                    x: .value("日期", selected.date, unit: .day),
                    y: .value("消费", selected.amount)
                )
                .symbolSize(40)
                .foregroundStyle(.orange)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: axisDates) { _ in
                AxisValueLabel(format: .dateTime.day(), centered: true)
            }
        }
        .chartYAxisLabel("元")
        .chartXSelection(value: $chartSelection)
    }
}
