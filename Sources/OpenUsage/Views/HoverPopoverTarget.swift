import SwiftUI

/// The shared hover-reveal machinery behind a row's detail popover — the per-model spend breakdown, or
/// the Codex rate-limit-resets timeline. Both the unbounded (text) rows and the bounded (meter) rows use
/// it, so a Today meter with a quota bar reveals its models exactly the way a Today text row does: same
/// highlight chip, same 400ms dwell, same anchor on the figure rather than the whole row.
extension View {
    /// Marks the value element as the popover's trigger and anchor. Applied to the figure itself — not
    /// the row — so hovering the label or the empty gap reveals nothing, and the arrow centers on the
    /// number the panel explains.
    func hoverPopoverTarget(
        data: WidgetData,
        hover: HoverPopoverState,
        enabled: Bool,
        highlighted: Bool,
        claim: CodexResetClaimService? = nil
    ) -> some View {
        modifier(HoverPopoverTarget(data: data, hover: hover, enabled: enabled,
                                    highlighted: highlighted, claim: claim))
    }

    /// Row-level teardown for a hover popover: drop it when the data behind it changes, and when the row
    /// leaves the tree. Applied to the whole row (the target modifier owns only the trigger/anchor).
    func hoverPopoverLifecycle(data: WidgetData, hover: HoverPopoverState) -> some View {
        modifier(HoverPopoverLifecycle(data: data, hover: hover))
    }
}

private struct HoverPopoverTarget: ViewModifier {
    let data: WidgetData
    let hover: HoverPopoverState
    let enabled: Bool
    let highlighted: Bool
    let claim: CodexResetClaimService?

    func body(content: Content) -> some View {
        content
            // A quaternary chip behind the value — the app's subtle-fill token, in the shared 6pt
            // continuous corner — signals the value is interactive before the breakdown even opens.
            // Negative-inset so it hugs the figure without changing the row's height (the text-row
            // rhythm that clusters Today / Yesterday / Last 30 Days must not shift), and a quick
            // opacity fade in/out matches macOS hover states.
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .padding(.horizontal, -7)
                    .padding(.vertical, -4)
                    .opacity(highlighted ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: highlighted)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard enabled else {
                    hover.dismiss()
                    return
                }
                if case .active = phase {
                    hover.inlineHover(true)
                } else {
                    hover.inlineHover(false)
                }
            }
            .popover(
                isPresented: Binding(
                    get: { enabled && hover.isPresented },
                    // A click-outside dismiss removes the detail view without an `.ended` hover event,
                    // so a plain assignment would strand `overDetail == true` and block future hides.
                    set: { if !$0 { hover.dismiss() } }
                ),
                arrowEdge: .top
            ) {
                detail
            }
    }

    @ViewBuilder
    private var detail: some View {
        if let breakdown = data.modelBreakdown {
            ModelUsageDetail(title: data.title, breakdown: breakdown) { inside in
                hover.detailHover(inside)
            }
        } else if data.showsResetExpiries {
            RateLimitResetsDetail(
                count: data.resetCreditCount, expiries: data.expiriesAt,
                onHoverChange: { inside in hover.detailHover(inside) },
                onPinChange: { pinned in hover.setPinned(pinned) },
                // Rows with reset expiries are Codex-only today, so the Codex claim service is the
                // right backing; absent from the environment (previews, share renders) the timeline
                // is read-only.
                claim: claim.map { service in
                    { expiry, redeemRequestID in
                        await service.claim(creditExpiringAt: expiry, redeemRequestID: redeemRequestID)
                    }
                }
            )
        }
    }
}

private struct HoverPopoverLifecycle: ViewModifier {
    let data: WidgetData
    let hover: HoverPopoverState

    func body(content: Content) -> some View {
        content
            .onChange(of: data.modelBreakdown) { _, _ in hover.dismiss() }
            // A refresh can replace the reset credits (count and expiries) while the popover is open;
            // drop it so it never lingers over a stale timeline — except while the claim flow has the
            // popover pinned: the claim's own forced refresh is what changes the credits, and dismissing
            // on it would close the popover before the claim's result banner ever renders. The pinned
            // popover re-renders from the new data instead (the detail view reconciles its own state).
            .onChange(of: data.expiriesAt) { _, _ in
                if !hover.isPinned { hover.dismiss() }
            }
            .onDisappear { hover.dismiss() }
    }
}
