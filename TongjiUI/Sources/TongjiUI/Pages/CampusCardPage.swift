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
            if store.transactions.isEmpty {
                Text("暂无消费记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.transactions.prefix(40), id: \.orderId) { transaction in
                    CampusCardTransactionRow(transaction: transaction)
                }
            }
        }
    }

    private var dailySpendingChartData: [CampusCardDailySpendingPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.transactions.filter { $0.signedAmountYuan < 0 }) { transaction in
            calendar.startOfDay(for: transaction.transactionDateTime)
        }
        return grouped
            .map { date, transactions in
                let total = transactions.reduce(0) { partial, item in
                    partial + abs(item.signedAmountYuan)
                }
                return CampusCardDailySpendingPoint(date: date, amount: total)
            }
            .sorted { $0.date < $1.date }
            .suffix(7)
            .map { $0 }
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
                Text(transaction.transactionDateTime.formatted(.dateTime.year().month().day().hour().minute()))
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

            if let chartSelection,
               let selected = data.first(where: {
                   Calendar.current.isDate($0.date, inSameDayAs: chartSelection)
               }) {
                RuleMark(x: .value("日期", selected.date, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, spacing: 0) {
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
