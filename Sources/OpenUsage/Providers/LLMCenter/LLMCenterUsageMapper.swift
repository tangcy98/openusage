import Foundation

/// Builds the provider's rows exclusively from official LLMCenter responses: the member-quota API
/// for the monthly meter and the usage-statistics API for the per-day figures. Nothing is summed from
/// per-call records; the only derived number is the Today soft daily quota, which the user asked for
/// explicitly (monthly quota ÷ days in the current month).
enum LLMCenterUsageMapper {
    /// The official monthly quota meter: spend against the effective quota, as a bounded `¥` progress
    /// row labelled "This Month". `nil` when the quota is not positive.
    static func quotaLine(spent: Double, quota: Double, breakdown: ModelUsageBreakdown? = nil) -> MetricLine? {
        guard quota > 0 else { return nil }
        return .progress(label: "This Month", used: max(0, spent), limit: quota, format: .yuan,
                         modelBreakdown: breakdown)
    }

    /// Today's soft daily quota: the official monthly quota spread over the current month's days.
    static func softDailyQuota(monthlyQuota: Double, now: Date, calendar: Calendar = .current) -> Double {
        let days = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        guard days > 0 else { return monthlyQuota }
        return monthlyQuota / Double(days)
    }

    /// Today's soft-quota meter: official spend against `softDailyQuota` (`¥` progress row). A meter
    /// shows one number, so today's token count lives only in the hover breakdown, not here.
    static func todayLine(cost: Double, softLimit: Double, breakdown: ModelUsageBreakdown? = nil) -> MetricLine {
        .progress(label: "Today", used: max(0, cost), limit: softLimit, format: .yuan,
                  modelBreakdown: breakdown)
    }

    /// Yesterday's official spend row (cost + tokens).
    static func yesterdayLine(cost: Double, tokens: Int, breakdown: ModelUsageBreakdown? = nil) -> MetricLine {
        .values(
            label: "Yesterday",
            values: [
                MetricValue(number: max(0, cost), kind: .yuan),
                MetricValue(number: Double(max(0, tokens)), kind: .count, label: "tokens")
            ],
            modelBreakdown: breakdown
        )
    }

    /// Per-model breakdown for the rows whose date matches `period` (a `yyyy-MM-dd` day key or a
    /// `yyyy-MM` month prefix), denominated in the rows' own CNY. `totalCost`/`totalTokens` are the
    /// period's official totals for the header.
    static func breakdown(
        rows: [[String: Any]],
        matching period: (String) -> Bool,
        totalCost: Double,
        totalTokens: Int
    ) -> ModelUsageBreakdown? {
        var byModel: [String: (tokens: Int, cost: Double)] = [:]
        for row in rows {
            guard let date = row["date"] as? String, period(date),
                  let model = (row["modelName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else { continue }
            let tokens = max(0, Int(ProviderParse.number(row["totalTokens"]) ?? 0))
            let cost = max(0, ProviderParse.number(row["cost"]) ?? 0)
            var entry = byModel[model] ?? (0, 0)
            entry.tokens += tokens
            entry.cost += cost
            byModel[model] = entry
        }
        guard !byModel.isEmpty else { return nil }

        let entries = byModel
            .map { name, totals in
                ModelUsageEntry(model: name, totalTokens: totals.tokens, costUSD: roundToCents(totals.cost))
            }
            .sorted { lhs, rhs in
                let lhsCost = lhs.costUSD ?? 0
                let rhsCost = rhs.costUSD ?? 0
                if lhsCost != rhsCost { return lhsCost > rhsCost }
                if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
            }
        return ModelUsageBreakdown(
            totalTokens: totalTokens,
            totalCostUSD: totalCost,
            models: entries,
            sourceNote: "From the LLMCenter usage API.",
            costKind: .yuan
        )
    }

    private static func roundToCents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// The Usage Trend row: one bar per calendar day of the current month, value = that day's spend in
    /// ¥ (the per-model detail rows summed per day). Days with no usage are zero-filled so the
    /// sparkline stays calendar-true, and the whole line is skipped when the month is idle — a flat row
    /// of zero bars would read as data. Spend rather than tokens: LLMCenter's rows are billed in ¥ and
    /// every other row on this provider reads in ¥, so the trend follows the same unit.
    static func trendLine(rows: [[String: Any]], now: Date, calendar: Calendar = .current) -> MetricLine? {
        var costByDay: [String: Double] = [:]
        for row in rows {
            guard let date = row["date"] as? String else { continue }
            costByDay[date, default: 0] += max(0, ProviderParse.number(row["cost"]) ?? 0)
        }
        guard costByDay.values.contains(where: { $0 > 0 }) else { return nil }

        let today = calendar.startOfDay(for: now)
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)),
              let elapsedDays = calendar.dateComponents([.day], from: monthStart, to: today).day
        else { return nil }

        let points = (0...elapsedDays).compactMap { offset -> MetricChartPoint? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monthStart) else { return nil }
            let key = DailyUsageAccumulator.dayKey(from: day, calendar: calendar)
            let cost = costByDay[key] ?? 0
            return MetricChartPoint(
                value: cost,
                label: Formatters.monthDayLabel(day),
                valueLabel: MetricFormatter.number(cost, kind: .yuan, style: .row)
            )
        }
        guard !points.isEmpty else { return nil }
        return .chart(label: "Usage Trend", points: points, note: "From the LLMCenter usage API.")
    }
}
