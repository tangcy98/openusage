import Foundation

/// How the menu-bar strip renders a bounded metric's value: the amount itself ("¥150", "$4"), or its
/// share of the limit ("2%"). Only affects metrics that have a limit *and* a unit other than percent —
/// a percent meter is a share by definition and reads the same either way, and an unbounded row (a bare
/// balance or spend total) has no limit to take a share of, so it always shows its amount.
///
/// Orthogonal to `WidgetDisplayMode` (Used/Left), which decides *which* number is being shown; this
/// decides how it's written. Both are global settings, so the strip and the dashboard agree.
enum MenuBarValueStyle: String, Hashable, Sendable, CaseIterable {
    case amount
    case percent

    var label: String {
        switch self {
        case .amount: return "Amount"
        case .percent: return "Percent"
        }
    }
}
