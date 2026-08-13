import XCTest
@testable import OpenUsage

/// Covers the Total Spend card's aggregation and metric projection: which providers contribute,
/// how slices rank per metric, Cost/MTok math, and when the combined number counts as estimated.
final class TotalSpendAggregatorTests: XCTestCase {
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    private func snapshot(_ provider: Provider, lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: lines,
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func spendLine(
        _ label: String,
        dollars: Double? = nil,
        tokens: Double? = 1_000_000,
        estimated: Bool = false
    ) -> MetricLine {
        var values: [MetricValue] = []
        if let dollars {
            values.append(MetricValue(number: dollars, kind: .dollars, estimated: estimated))
        }
        if let tokens {
            values.append(MetricValue(number: tokens, kind: .count, label: "tokens"))
        }
        return .values(label: label, values: values)
    }

    func testSumsDollarsAndTokensAcrossProviders() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50, tokens: 100_000, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7.25, tokens: 500_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)

        XCTAssertEqual(Set(total.slices.map(\.provider.id)), Set(["cursor", "claude"]))
        XCTAssertEqual(total.totalUSD, 9.75, accuracy: 0.0001)
        XCTAssertEqual(total.totalTokens, 600_000, accuracy: 0.0001)

        let spend = total.projection(for: .cost)
        XCTAssertEqual(spend.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(spend.centerValue, 9.75, accuracy: 0.0001)
    }

    func testSlicesCarryTheCallerResolvedTitleThroughProjection() {
        // The caller (the live card, with registry access) resolves each slice's title once; the
        // legend and the share export both read that resolved string, so a mid-session rename can
        // never show on one and not the other.
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7.25)])
        ]

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [claude, cursor],
            snapshots: snapshots,
            title: { $0.id == "claude" ? "Claude Team" : $0.displayName }
        )

        XCTAssertEqual(total.projection(for: .cost).slices.map(\.title), ["Cursor", "Claude Team"])
    }

    func testProviderWithoutPeriodLineIsExcludedNotZero() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 1.00)]),
            // Codex has spend for yesterday only — it must not appear in today's slices.
            "codex": snapshot(codex, lines: [spendLine("Yesterday", dollars: 3.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex], snapshots: snapshots)

        XCTAssertEqual(total.slices.map(\.provider.id), ["claude"])
    }

    func testTokensOnlyLineContributesTokensButNotSpendOrCostPerMtok() {
        let tokensOnly = spendLine("Today", dollars: nil, tokens: 500_000)
        let snapshots = ["claude": snapshot(claude, lines: [tokensOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertFalse(total.isEmpty)
        XCTAssertEqual(total.slices.first?.tokenCount, 500_000)
        XCTAssertEqual(total.slices.first?.amountUSD, 0)

        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)

        let tokens = total.projection(for: .tokens)
        XCTAssertEqual(tokens.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(tokens.centerValue, 500_000, accuracy: 0.0001)
    }

    func testDollarsOnlyLineContributesSpendButNotCostPerMtok() {
        let dollarsOnly = spendLine("Today", dollars: 4.00, tokens: nil)
        let snapshots = ["claude": snapshot(claude, lines: [dollarsOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertEqual(total.projection(for: .cost).centerValue, 4.00, accuracy: 0.0001)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testTotalIsEstimatedWhenAnySliceIsEstimated() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.00, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 4.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)

        XCTAssertTrue(total.isEstimated)
        XCTAssertTrue(total.projection(for: .cost).isEstimated)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEstimated)
        XCTAssertFalse(total.projection(for: .tokens).isEstimated)
    }

    func testCostPerMtokRanksByRateAndBlendsTotals() {
        // Claude: $10 / 1M tokens = $10/MTok
        // Cursor: $30 / 1M tokens = $30/MTok — ranks first by rate
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 30, tokens: 1_000_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertEqual(rates.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(rates.slices[0].displayAmount, 30, accuracy: 0.0001)
        XCTAssertEqual(rates.slices[1].displayAmount, 10, accuracy: 0.0001)
        // Blended center: ($40 / 2M) * 1e6 = $20/MTok
        XCTAssertEqual(rates.centerValue, 20, accuracy: 0.0001)
    }

    func testCostPerMtokExcludesIncompleteProvidersFromBlend() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "codex": snapshot(codex, lines: [spendLine("Today", dollars: nil, tokens: 9_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 5, tokens: nil)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertEqual(rates.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(rates.centerValue, 10, accuracy: 0.0001)
    }

    func testTokensProjectionRanksByTokenCount() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 50, tokens: 100_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 1, tokens: 900_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let tokens = total.projection(for: .tokens)

        XCTAssertEqual(tokens.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(tokens.centerValue, 1_000_000, accuracy: 0.0001)
    }

    func testEmptyProjectionWhenNothingQualifies() {
        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: [:])
        XCTAssertTrue(total.isEmpty)
        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    // MARK: - CNY providers

    private let llmcenter = Provider(id: "llmcenter", displayName: "LLMCenter", icon: .providerMark("llmcenter"))

    func testYuanValuesConvertToDollarsAtTheSuppliedRate() {
        // A CNY-billed provider's row must be converted before it joins a dollar total — summing the
        // raw yuan figure would inflate both the center number and every provider's share.
        let snapshots = [
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7, tokens: nil)]),
            "llmcenter": snapshot(llmcenter, lines: [
                .values(label: "Today", values: [
                    MetricValue(number: 100, kind: .yuan),
                    MetricValue(number: 500_000, kind: .count, label: "tokens")
                ])
            ])
        ]

        let total = TotalSpendAggregator.total(
            for: .today, providers: [cursor, llmcenter], snapshots: snapshots, usdPerCNY: 0.15
        )

        XCTAssertEqual(total.totalUSD, 22, accuracy: 0.0001)   // 7 + 100 × 0.15
        XCTAssertEqual(total.totalTokens, 500_000, accuracy: 0.0001)
        // The rate is a live quote, so anything converted through it is an approximation.
        XCTAssertTrue(total.slices.first { $0.provider.id == "llmcenter" }?.estimated == true)
        XCTAssertFalse(total.slices.first { $0.provider.id == "cursor" }?.estimated == true)
    }

    func testYuanMeterContributesItsUsedSideConverted() {
        // LLMCenter's Today row is a soft-quota meter, not a `.values` row: the aggregator reads the
        // "used" side as the period's spend so a meter-shaped provider isn't silently dropped.
        let snapshots = [
            "llmcenter": snapshot(llmcenter, lines: [
                .progress(label: "Today", used: 200, limit: 225, format: .yuan)
            ])
        ]

        let total = TotalSpendAggregator.total(
            for: .today, providers: [llmcenter], snapshots: snapshots, usdPerCNY: 0.15
        )

        XCTAssertEqual(total.totalUSD, 30, accuracy: 0.0001)
        XCTAssertEqual(total.totalTokens, 0, accuracy: 0.0001)
        XCTAssertTrue(total.isEstimated)
    }

    func testPercentAndCountMetersContributeNothing() {
        // Only money meters carry spend. A percent or count meter labeled "Today" has no dollar
        // meaning, so it must be excluded rather than counted as its raw number.
        let snapshots = [
            "claude": snapshot(claude, lines: [.progress(label: "Today", used: 60, limit: 100, format: .percent)]),
            "codex": snapshot(codex, lines: [
                .progress(label: "Today", used: 412, limit: 500, format: .count(suffix: "requests"))
            ])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex], snapshots: snapshots)

        XCTAssertTrue(total.isEmpty)
    }
}
