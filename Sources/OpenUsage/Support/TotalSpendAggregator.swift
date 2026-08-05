import Foundation

/// The spend period the Total Spend card can show — matching the three per-provider spend tiles
/// `SpendTileMapper` emits, whose line labels double as the lookup keys here.
enum TotalSpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last30 = "Last 30 Days"

    var id: String { rawValue }

    /// The metric-line label this period sums across providers (identical to the raw value today,
    /// but kept as its own accessor so the two meanings can diverge without a hunt).
    var lineLabel: String { rawValue }

    /// Compact segment title for the period switcher — "Last 30 Days" doesn't fit three-across
    /// in the 320pt popover without shrinking every segment.
    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30: "30 Days"
        }
    }
}

/// Which quantity the Total Spend card's ring, center, and legend show. The title menu persists this
/// choice; the aggregator always collects both dollars and tokens so flipping modes doesn't re-scan.
/// Raw value `apiSpend` is kept so existing installs don't lose their stored Cost selection.
enum TotalSpendMetric: String, CaseIterable, Identifiable, Sendable {
    /// Menu order is declaration order: Cost → Cost/MTok → Tokens. Cost is the default.
    case cost = "apiSpend"
    case costPerMtok
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: "Cost"
        case .costPerMtok: "Cost/MTok"
        case .tokens: "Tokens"
        }
    }

    /// Empty-state copy when no provider qualifies for this metric in the selected period.
    var emptyMessage: String {
        switch self {
        case .cost: "No cost data for this period"
        case .costPerMtok: "No cost-per-token data for this period"
        case .tokens: "No token data for this period"
        }
    }

    /// Dollar-backed modes can inherit the local-estimate note when any contributor's spend is imputed.
    var usesDollarEstimateNote: Bool {
        switch self {
        case .cost, .costPerMtok: true
        case .tokens: false
        }
    }
}

/// One provider's contribution to a period's total: dollars and tokens from the same spend line,
/// plus whether the dollars are a local estimate (log-scanned providers) or measured (Cursor's CSV).
struct TotalSpendSlice: Identifiable, Equatable {
    let provider: Provider
    /// The card title, resolved by the aggregation's caller through the one name resolver — so the
    /// legend, the ranking tie-break, and the share-card export (which renders outside the SwiftUI
    /// environment and can't resolve for itself) all show the same live name.
    let title: String
    let amountUSD: Double
    let tokenCount: Double
    let estimated: Bool

    var id: String { provider.id }

    /// Dollars per million tokens for this provider alone. `nil` when either side is missing.
    var costPerMtok: Double? {
        guard amountUSD > 0, tokenCount > 0 else { return nil }
        return (amountUSD / tokenCount) * 1_000_000
    }
}

/// One provider's ready-to-draw contribution under a chosen metric: the amount that sizes the ring
/// and ranks the legend, plus the formatted value surfaces read through `MetricFormatter`.
struct TotalSpendProjectedSlice: Identifiable, Equatable {
    let provider: Provider
    /// The already-resolved card title (see `TotalSpendSlice.title`) — what the legend renders.
    let title: String
    let displayAmount: Double
    let estimated: Bool

    var id: String { provider.id }
}

/// A period's cross-provider totals under one metric: ranked slices, center value, and estimate flag.
struct TotalSpendProjection: Equatable {
    let metric: TotalSpendMetric
    let slices: [TotalSpendProjectedSlice]
    let centerValue: Double
    let isEstimated: Bool

    var isEmpty: Bool { slices.isEmpty }
}

/// A period's cross-provider raw totals: every spend-capable provider that contributed dollars and/or
/// tokens. Presentation (include / rank / center) is `projection(for:)`.
struct TotalSpend: Equatable {
    let period: TotalSpendPeriod
    let slices: [TotalSpendSlice]

    var totalUSD: Double { slices.reduce(0) { $0 + $1.amountUSD } }
    var totalTokens: Double { slices.reduce(0) { $0 + $1.tokenCount } }
    /// The combined number is an estimate as soon as any contributor's dollars are imputed locally.
    var isEstimated: Bool { slices.contains(where: \.estimated) }
    /// Raw storage empty — no provider had dollars or tokens for the period.
    var isEmpty: Bool { slices.isEmpty }

    /// Filters, ranks, and computes the center value for the title menu's selected metric.
    func projection(for metric: TotalSpendMetric) -> TotalSpendProjection {
        let included: [(slice: TotalSpendSlice, display: Double)] = slices.compactMap { slice in
            switch metric {
            case .cost:
                guard slice.amountUSD > 0 else { return nil }
                return (slice, slice.amountUSD)
            case .tokens:
                guard slice.tokenCount > 0 else { return nil }
                return (slice, slice.tokenCount)
            case .costPerMtok:
                guard let rate = slice.costPerMtok else { return nil }
                return (slice, rate)
            }
        }

        let ranked = included.sorted { lhs, rhs in
            if lhs.display != rhs.display { return lhs.display > rhs.display }
            return lhs.slice.title.localizedStandardCompare(rhs.slice.title) == .orderedAscending
        }

        let projected = ranked.map {
            TotalSpendProjectedSlice(
                provider: $0.slice.provider,
                title: $0.slice.title,
                displayAmount: $0.display,
                estimated: $0.slice.estimated
            )
        }

        let center: Double
        let estimated: Bool
        switch metric {
        case .cost:
            center = ranked.reduce(0) { $0 + $1.slice.amountUSD }
            estimated = ranked.contains { $0.slice.estimated }
        case .tokens:
            center = ranked.reduce(0) { $0 + $1.slice.tokenCount }
            estimated = false
        case .costPerMtok:
            let usd = ranked.reduce(0) { $0 + $1.slice.amountUSD }
            let tokens = ranked.reduce(0) { $0 + $1.slice.tokenCount }
            center = tokens > 0 ? (usd / tokens) * 1_000_000 : 0
            estimated = ranked.contains { $0.slice.estimated }
        }

        return TotalSpendProjection(metric: metric, slices: projected, centerValue: center, isEstimated: estimated)
    }
}

/// Sums per-provider daily spend into one cross-provider total — the data source for the dashboard's
/// Total Spend ring card. Pure and synchronous: it reads already-refreshed `ProviderSnapshot`s and
/// never fetches. A provider contributes when its snapshot carries a line with the period's label
/// *and* that line has money and/or tokens — idle periods (no line) are excluded, never zero.
///
/// Both line shapes count: the usual `.values` spend row, and a `.progress` quota meter carrying the
/// period's spend (LLM Center's Today / This Month meters). A meter's "used" side is the same spend
/// figure a values row reports, so excluding it would drop a real contributor from the ring.
enum TotalSpendAggregator {
    /// The total for one period across `providers` (pass them in display order; ties keep it).
    /// Slices keep provider display order input only as a stable traversal; metric projection re-ranks.
    /// `title` resolves each provider's card title — the live card passes the account-registry
    /// resolver so slices carry renames; the default is the baked derived name for callers without
    /// registry access (tests).
    ///
    /// `usdPerCNY` converts the yuan-billed providers into the ring's dollar domain. A converted
    /// contribution is always marked `estimated`: the rate is a daily snapshot of a moving market, so
    /// the total it feeds is an approximation no matter how the provider itself measured the spend.
    static func total(
        for period: TotalSpendPeriod,
        providers: [Provider],
        snapshots: [String: ProviderSnapshot],
        usdPerCNY: Double = ExchangeRateStore.fallbackUSDPerCNY,
        title: (Provider) -> String = { $0.displayName }
    ) -> TotalSpend {
        let slices = providers.compactMap { provider -> TotalSpendSlice? in
            guard let snapshot = snapshots[provider.id],
                  let line = snapshot.line(label: period.lineLabel),
                  let spend = money(in: line, usdPerCNY: usdPerCNY) else { return nil }
            guard spend.amountUSD > 0 || spend.tokens > 0 else { return nil }

            return TotalSpendSlice(
                provider: provider,
                title: title(provider),
                amountUSD: max(spend.amountUSD, 0),
                tokenCount: max(spend.tokens, 0),
                estimated: spend.estimated
            )
        }
        return TotalSpend(period: period, slices: slices)
    }

    /// This period's dollars and tokens from one metric line, or `nil` when the line carries neither.
    private static func money(
        in line: MetricLine,
        usdPerCNY: Double
    ) -> (amountUSD: Double, tokens: Double, estimated: Bool)? {
        switch line {
        case .values(_, let values, _, _, _, _):
            let dollars = values.filter { $0.kind == .dollars }
            let yuan = values.filter { $0.kind == .yuan }
            let amount = dollars.reduce(0) { $0 + $1.number }
                + yuan.reduce(0) { $0 + $1.number } * usdPerCNY
            let tokens = values
                .filter { $0.kind == .count && $0.label == "tokens" }
                .reduce(0) { $0 + $1.number }
            return (amount, tokens, dollars.contains(where: \.estimated) || !yuan.isEmpty)
        case .progress(_, let used, _, let format, _, _, _, _):
            // A meter has one number and no token count; its "used" side is the period's spend.
            switch format {
            case .dollars: return (used, 0, false)
            case .yuan: return (used * usdPerCNY, 0, true)
            case .percent, .count: return nil
            }
        case .text, .chart, .badge:
            return nil
        }
    }
}
