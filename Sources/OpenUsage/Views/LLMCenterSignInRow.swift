import SwiftUI

/// The in-app sign-in affordance on the LLM Center card, shown when the saved token has expired.
///
/// It exists because `llmctl auth login` cannot recover from an expired token — it treats any non-empty
/// `web_token` as "already signed in" and returns without contacting the server — so the usual "run the
/// CLI again" instruction is a dead end for this provider. The row sits above the caret rather than
/// behind it: the card is showing stale numbers precisely because the login broke, so the way out must
/// not be hidden.
///
/// Renders nothing without a service in the environment (previews, share-card renders), matching how the
/// Codex reset-claim affordance behaves.
struct LLMCenterSignInRow: View {
    @Environment(\.llmCenterSignIn) private var signIn
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// Matches the metric row and quick-link inset so the button lines up with the card's content edges.
    private static let horizontalInset: CGFloat = 14
    /// How long a success stays on screen before the row hands itself back to the button. Only matters
    /// when the follow-up refresh also fails — otherwise the error clears and the row disappears first.
    private static let successLinger: Duration = .seconds(2)

    var body: some View {
        if let signIn {
            content(signIn)
                .padding(.horizontal, Self.horizontalInset)
                .padding(.top, density.textRowPadding)
                .padding(.bottom, density.textRowPadding)
                .animation(Motion.spring, value: signIn.phase)
                .task(id: signIn.phase) {
                    guard signIn.phase == .succeeded else { return }
                    try? await Task.sleep(for: Self.successLinger)
                    guard !Task.isCancelled else { return }
                    signIn.dismissResult()
                }
        }
    }

    @ViewBuilder
    private func content(_ signIn: LLMCenterSignInService) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .failed(let message) = signIn.phase {
                notice(message)
            }
            switch signIn.phase {
            case .starting, .awaitingBrowser:
                waiting(signIn)
            case .succeeded:
                notice("Signed In. Refreshing…", color: AnyShapeStyle(.secondary))
            case .idle, .failed:
                signInButton(signIn)
            }
        }
    }

    private func signInButton(_ signIn: LLMCenterSignInService) -> some View {
        Button {
            signIn.signIn()
        } label: {
            HStack(spacing: 4) {
                Text("Sign In to LLM Center")
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: density.supportingPointSize - 2))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("Sign in to LLM Center, opens in browser")
    }

    private func waiting(_ signIn: LLMCenterSignInService) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Waiting for Browser…")
                .font(.system(size: density.supportingPointSize, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Cancel") { signIn.cancel() }
                .buttonStyle(.plain)
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String, color: AnyShapeStyle = Theme.notice) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
