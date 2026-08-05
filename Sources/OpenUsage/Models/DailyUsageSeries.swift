import Foundation

/// A provider-neutral per-day token/cost series — the shared carrier every spend-tracking provider
/// funnels through `SpendTileMapper` (the Today / Yesterday / Last 30 Days tiles and the Usage Trend
/// chart).
///
/// Sources build it from very different inputs and hand `SpendTileMapper` the same shape so the tiles
/// render identically regardless of origin: Claude/Codex/Grok from their native log scanners, Cursor
/// from its usage CSV export.
///
/// These are internal types with no serialization impact: the local HTTP API serializes `MetricLine`,
/// not these.
struct DailyUsageEntry: Hashable, Sendable, Codable {
    var date: String
    var totalTokens: Int
    var costUSD: Double?
}

struct DailyUsageSeries: Hashable, Sendable, Codable {
    var daily: [DailyUsageEntry]
}

/// The calendar window shared by local scanners, combined iCloud history, and the usage trend.
/// `previousDays` excludes today, so 30 means today plus the previous 30 calendar days.
enum UsageHistoryWindow {
    static let previousDays = 30

    static func dayKeys(through now: Date, calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        return Set((0...previousDays).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
        })
    }
}

/// Token/cost totals for one model before a period collapses it into a spend row. Costs stay unrounded
/// here; `SpendTileMapper` snaps them to cents once for the displayed Today / Yesterday / Last 30 Days
/// breakdown, matching the spend-row totals.
///
/// `variants` carries the raw slugs folded into this entry when a provider groups by base model —
/// Cursor's thinking-effort/fast CSV slugs (`claude-opus-4-8-thinking-max` under `claude-opus-4-8`) —
/// and the models rolled into the `Other` row. Nil when the entry is exactly one raw model (the log
/// scanners' entries), so the hover panel knows there is no finer breakdown to offer.
struct ModelUsageEntry: Hashable, Sendable, Codable {
    static let unattributedModelName = "Unattributed"
    static let otherModelName = "Other"

    var model: String
    var totalTokens: Int
    var costUSD: Double?
    var variants: [ModelUsageVariant]? = nil
}

/// One raw slug inside a grouped `ModelUsageEntry` — the "per thinking effort" line of the hover
/// panel's row tooltip.
struct ModelUsageVariant: Hashable, Sendable, Codable {
    var model: String
    var totalTokens: Int
    var costUSD: Double?
}

struct DailyModelUsageEntry: Hashable, Sendable, Codable {
    var date: String
    var models: [ModelUsageEntry]
}

struct ModelUsageSeries: Hashable, Sendable, Codable {
    var daily: [DailyModelUsageEntry]
}

/// The presentation-free daily history retained on a provider snapshot. The same normalized values
/// feed the local spend rows and, when explicitly classified as machine-local by the provider's
/// descriptor, the private iCloud sync file.
struct ProviderUsageHistory: Hashable, Sendable, Codable {
    var series: DailyUsageSeries
    var modelUsage: ModelUsageSeries?
    var unknownModelsByDay: [String: Set<String>]

    init(
        series: DailyUsageSeries,
        modelUsage: ModelUsageSeries? = nil,
        unknownModelsByDay: [String: Set<String>] = [:]
    ) {
        self.series = series
        self.modelUsage = modelUsage
        self.unknownModelsByDay = unknownModelsByDay
    }
}

/// A period-scoped, UI-ready breakdown attached to the same `.values` line as the spend row it explains.
/// The header total mirrors that row's values; individual model costs are rounded at this display boundary.
/// `costKind` says how the breakdown's costs are denominated — `.dollars` for the existing USD spend rows,
/// `.yuan` for CNY-billed providers — so the hover panel renders the same symbol the row shows.
struct ModelUsageBreakdown: Hashable, Sendable, Codable {
    var totalTokens: Int
    var totalCostUSD: Double?
    var models: [ModelUsageEntry]
    var sourceNote: String
    var costKind: MetricKind = .dollars

    // Restated because writing any initializer suppresses the synthesized memberwise one, and the
    // custom `init(from:)` below is required.
    init(
        totalTokens: Int,
        totalCostUSD: Double?,
        models: [ModelUsageEntry],
        sourceNote: String,
        costKind: MetricKind = .dollars
    ) {
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.models = models
        self.sourceNote = sourceNote
        self.costKind = costKind
    }

    /// Hand-written only to tolerate a missing `costKind`: the synthesized decode throws on an absent
    /// key, which would drop every snapshot cached before this field existed. `CodingKeys` and
    /// `encode(to:)` stay synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        totalCostUSD = try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
        models = try container.decode([ModelUsageEntry].self, forKey: .models)
        sourceNote = try container.decode(String.self, forKey: .sourceNote)
        costKind = try container.decodeIfPresent(MetricKind.self, forKey: .costKind) ?? .dollars
    }
}

/// Daily token/cost series plus the per-day models the pricing sources couldn't price — the inputs
/// `SpendTileMapper.appendTokenUsage` needs to render the spend tiles with unknown-model warnings.
/// Shared result shape of the native log scanners (Claude, Codex).
struct LogUsageScan: Sendable {
    var series: DailyUsageSeries
    var modelUsage: ModelUsageSeries?
    /// `yyyy-MM-dd` day key → models used that day whose usage was left out because no price was available.
    var unknownModelsByDay: [String: Set<String>]

    init(series: DailyUsageSeries, modelUsage: ModelUsageSeries? = nil, unknownModelsByDay: [String: Set<String>]) {
        self.series = series
        self.modelUsage = modelUsage
        self.unknownModelsByDay = unknownModelsByDay
    }
}
