import Foundation
import Security
import SwiftUI

/// Runs the LLMCenter CLI authorization from inside the app, so signing in — first time or after an
/// expiry — never requires dropping to a terminal. The protocol needs no existing credential at all;
/// see docs/research/llm-center-api.md.
///
/// This object is the single in-flight gate for both entry points (the card's button and the automatic
/// mode), which is why the phase lives here rather than as view state: two browser windows for one login
/// would be worse than no automation at all.
@MainActor
@Observable
final class LLMCenterSignInService {
    enum Phase: Equatable, Sendable {
        case idle
        case starting
        case awaitingBrowser
        case succeeded
        case failed(String)

        var isInFlight: Bool { self == .starting || self == .awaitingBrowser }
    }

    var phase: Phase = .idle

    private let authStore: LLMCenterAuthStore
    private let client: LLMCenterAuthClient
    private let openURL: @MainActor (URL) -> Void
    private let refreshAfterSignIn: () async -> Void
    private let now: @Sendable () -> Date
    private let makeState: @Sendable () throws -> String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let hasCompletedFirstRefresh: @MainActor () -> Bool
    private let autoSignInInterval: @Sendable () -> LLMCenterAutoSignInInterval

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The timer task started when automatic sign-in discovers an expiry. Fires after the configured
    /// interval unless the login recovers in the meantime (from a manual sign-in, external llmctl update,
    /// or any other source). Canceled on successful refresh or when the user signs in manually.
    @ObservationIgnored private var expiryTimer: Task<Void, Never>?
    /// Set after an automatic sign-in attempt fails (timeout, server rejection, or any error). Cleared
    /// when a refresh succeeds, so the next expiry can trigger automatic sign-in again. Prevents repeated
    /// browser windows for a dead session.
    @ObservationIgnored private var autoSignInBlocked = false

    init(
        authStore: LLMCenterAuthStore,
        client: LLMCenterAuthClient = LLMCenterAuthClient(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        refreshAfterSignIn: @escaping () async -> Void = {},
        now: @escaping @Sendable () -> Date = Date.init,
        makeState: @escaping @Sendable () throws -> String = LLMCenterSignInService.makeState,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        hasCompletedFirstRefresh: @escaping @MainActor () -> Bool = { true },
        autoSignInInterval: @escaping @Sendable () -> LLMCenterAutoSignInInterval = {
            guard let raw = UserDefaults.standard.string(forKey: LLMCenterAutoSignInSetting.key) else {
                return LLMCenterAutoSignInSetting.defaultValue
            }
            return LLMCenterAutoSignInInterval(rawValue: raw) ?? LLMCenterAutoSignInSetting.defaultValue
        }
    ) {
        self.authStore = authStore
        self.client = client
        self.openURL = openURL
        self.refreshAfterSignIn = refreshAfterSignIn
        self.now = now
        self.makeState = makeState
        self.sleep = sleep
        self.hasCompletedFirstRefresh = hasCompletedFirstRefresh
        self.autoSignInInterval = autoSignInInterval
    }

    /// The card button's entry point. Returns false when a sign-in is already running, so a double-click
    /// can't open two browser windows. Cancels any running timer: a manual sign-in supersedes the delay.
    @discardableResult
    func signIn() -> Bool {
        guard !phase.isInFlight else { return false }
        expiryTimer?.cancel()
        expiryTimer = nil
        phase = .starting
        pollTask = Task { [weak self] in
            await self?.run()
        }
        return true
    }

    /// The manual refresh path: called when a forced refresh discovers an expired login. Opens the
    /// browser immediately, regardless of the configured interval.
    func signInManually() {
        guard !phase.isInFlight else { return }
        guard !autoSignInBlocked else {
            AppLog.debug(LogTag.auth("llmcenter"), "manual sign-in skipped: auto sign-in failed earlier and login has not recovered")
            return
        }
        expiryTimer?.cancel()
        expiryTimer = nil
        AppLog.info(LogTag.auth("llmcenter"), "manual refresh triggered sign-in immediately")
        signIn()
    }

    /// The automatic refresh path: called when a background refresh discovers an expired login. Starts
    /// a timer (or triggers immediately if the interval is zero) unless the setting is `never`, a sign-in
    /// is already running, or automatic sign-in was blocked after an earlier failure.
    func signInAutomatically(interval: LLMCenterAutoSignInInterval) {
        guard interval != .never else { return }
        guard !phase.isInFlight else { return }
        guard !autoSignInBlocked else {
            AppLog.debug(LogTag.auth("llmcenter"), "auto sign-in blocked: earlier attempt failed and login has not recovered")
            return
        }
        guard expiryTimer == nil else {
            AppLog.debug(LogTag.auth("llmcenter"), "auto sign-in timer already running")
            return
        }
        // A refresh that fails during launch would open a browser before the user has even seen the
        // dashboard. Wait until the app has completed a refresh pass first.
        guard hasCompletedFirstRefresh() else {
            AppLog.debug(LogTag.auth("llmcenter"), "auto sign-in skipped: no refresh pass has completed yet")
            return
        }

        guard let delay = interval.seconds else { return }
        if delay == 0 {
            AppLog.info(LogTag.auth("llmcenter"), "auto sign-in starting immediately after expired-login discovery")
            signIn()
        } else {
            AppLog.info(LogTag.auth("llmcenter"), "auto sign-in timer started: \(Int(delay))s until browser opens")
            expiryTimer = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    await self?.fireTimer()
                } catch {
                    // Cancellation or sleep failure; either way the timer ends here.
                }
            }
        }
    }

    /// Clears the automatic sign-in block and cancels any running timer. Called when a refresh succeeds,
    /// so the next expiry can trigger automatic sign-in again.
    func clearAutoSignInBlock() {
        autoSignInBlocked = false
        expiryTimer?.cancel()
        expiryTimer = nil
    }

    private func fireTimer() {
        expiryTimer = nil
        guard !phase.isInFlight else {
            AppLog.debug(LogTag.auth("llmcenter"), "auto sign-in timer fired but sign-in already in flight")
            return
        }
        AppLog.info(LogTag.auth("llmcenter"), "auto sign-in timer fired; opening browser")
        signIn()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    /// Clears a terminal result so the row returns to its button. Called by the row after a success has
    /// been on screen briefly, and when the user dismisses a failure.
    func dismissResult() {
        guard !phase.isInFlight else { return }
        phase = .idle
    }

    /// The `llmctl_` prefix the server requires on an OIDC CLI `state`, then 48 hex characters from the
    /// system CSPRNG. A sign-in nonce must be unguessable, and a `SecRandomCopyBytes` failure is surfaced
    /// as an error rather than falling back to a weaker source.
    nonisolated static let statePrefix = "llmctl_"

    nonisolated static func makeState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            AppLog.error(LogTag.auth("llmcenter"), "SecRandomCopyBytes failed; cannot generate a sign-in state")
            throw LLMCenterSignInError.stateUnavailable
        }
        return statePrefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func run() async {
        defer { pollTask = nil }
        do {
            let api = try await loadOffMainActor { [authStore] in try authStore.loadAPIBaseURL() }
            let state = try makeState()
            let pkce = try LLMCenterPKCE.generate()
            let session = try await client.createSession(
                api: api, state: state, pkce: pkce, redirectUri: Self.redirectURI(api: api)
            )
            guard !Task.isCancelled else { return }

            phase = .awaitingBrowser
            AppLog.info(
                LogTag.auth("llmcenter"),
                "opening the authorization page: \(LogRedaction.redactURL(session.authorizeURL.absoluteString))"
            )
            openURL(session.authorizeURL)

            let code = try await awaitAuthorization(api: api, session: session)
            guard !Task.isCancelled else { return }

            let token = try await client.exchangeAuthorizationCode(session: session, code: code)
            guard !Task.isCancelled else { return }

            let oidc = LLMCenterOIDCMetadata(
                tokenEndpoint: session.tokenEndpoint, clientId: session.clientId, redirectUri: session.redirectUri
            )
            try await loadOffMainActor { [authStore, now] in
                try authStore.save(token, api: api, source: .signIn(oidc), now: now())
            }
            // No refresh token means the login lapses after the access token's lifetime and the next
            // expiry needs the browser again; log it so a server-side change doesn't pass unnoticed.
            if token.refreshToken == nil {
                AppLog.warn(LogTag.auth("llmcenter"), "sign-in response carried no refresh token; this login can't be renewed silently")
            }
            AppLog.info(LogTag.auth("llmcenter"), "sign-in complete; saved a new token to the config file")

            await refreshAfterSignIn()
            guard !Task.isCancelled else { return }
            phase = .succeeded
        } catch is CancellationError {
            // `cancel()` already reset the phase.
        } catch {
            // The detail is the only diagnostic trace of a `sessionFailed`: every case shares one
            // friendly sentence, and the UI copy is fixed, so the log is where it has to land.
            let detail = (error as? LLMCenterSignInError)?.diagnosticDetail
            AppLog.error(
                LogTag.auth("llmcenter"),
                "sign-in failed: \(error.localizedDescription)\(detail.map { " (detail: \($0))" } ?? "")"
            )
            autoSignInBlocked = true
            phase = .failed(error.localizedDescription)
        }
    }

    /// The OIDC redirect the authorization page sends the user back to once they approve. It must be the
    /// same value at session creation and token exchange, so it is derived once from the API base and
    /// passed to both.
    nonisolated static func redirectURI(api: String) -> String? {
        guard var components = URLComponents(string: api.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty
        else { return nil }
        components.path = "/auth/callback"
        components.query = nil
        components.fragment = nil
        return components.string
    }

    /// Polls until the server hands back an authorization code, the user is refused, or the session
    /// expires. Transient transport failures are retried a bounded number of times — the poll is a safe
    /// GET, and a single dropped request should not discard an authorization the user already completed.
    private func awaitAuthorization(
        api: String, session: LLMCenterAuthSession
    ) async throws -> String {
        let deadline = now().addingTimeInterval(min(session.expiresIn, 600))
        var transportFailures = 0
        while true {
            try await sleep(session.pollInterval)
            try Task.checkCancellation()
            guard now() < deadline else { throw LLMCenterSignInError.timedOut }

            let result: LLMCenterAuthPoll
            do {
                result = try await client.poll(api: api, state: session.state)
                transportFailures = 0
            } catch {
                transportFailures += 1
                guard transportFailures <= 2 else { throw error }
                AppLog.warn(
                    LogTag.auth("llmcenter"),
                    "poll attempt failed (\(transportFailures)/2), retrying: \(error.localizedDescription)"
                )
                continue
            }

            switch result {
            case .pending:
                continue
            case .authorized(let code):
                return code
            case .rejected(let code):
                throw LLMCenterSignInError.pollFailed(code: code)
            }
        }
    }
}

/// Hands the sign-in service to the dashboard through the environment: `nil` (the default — previews,
/// share-card renders, reorder previews) renders the card with no sign-in affordance.
private struct LLMCenterSignInServiceKey: EnvironmentKey {
    static let defaultValue: LLMCenterSignInService? = nil
}

extension EnvironmentValues {
    var llmCenterSignIn: LLMCenterSignInService? {
        get { self[LLMCenterSignInServiceKey.self] }
        set { self[LLMCenterSignInServiceKey.self] = newValue }
    }
}
