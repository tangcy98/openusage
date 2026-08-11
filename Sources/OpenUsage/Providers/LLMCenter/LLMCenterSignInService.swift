import Foundation
import Security
import SwiftUI

/// Runs the LLM Center CLI authorization from inside the app, so an expired token can be replaced without
/// dropping to a terminal. `llmctl auth login` cannot do this: it treats any non-empty `web_token` in
/// `config.json` as "already signed in" and returns without contacting the server, so an expired token
/// makes the CLI a dead end. The protocol is the same one the CLI uses — see
/// docs/research/llm-center-api.md.
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
    private let isAutoEnabled: @Sendable () -> Bool

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The automatic mode fires at most once per app session. A dead SSO session would otherwise make
    /// every failed refresh throw another browser window at the user; one attempt per launch recovers the
    /// ordinary expiry case and leaves the card's button for anything worse.
    @ObservationIgnored private var autoAttemptedThisSession = false

    init(
        authStore: LLMCenterAuthStore,
        client: LLMCenterAuthClient = LLMCenterAuthClient(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        refreshAfterSignIn: @escaping () async -> Void = {},
        now: @escaping @Sendable () -> Date = Date.init,
        makeState: @escaping @Sendable () throws -> String = LLMCenterSignInService.makeState,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        hasCompletedFirstRefresh: @escaping @MainActor () -> Bool = { true },
        isAutoEnabled: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: LLMCenterAutoSignInSetting.key, default: false)
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
        self.isAutoEnabled = isAutoEnabled
    }

    /// The card button's entry point. Returns false when a sign-in is already running, so a double-click
    /// can't open two browser windows.
    @discardableResult
    func signIn() -> Bool {
        guard !phase.isInFlight else { return false }
        phase = .starting
        pollTask = Task { [weak self] in
            await self?.run()
        }
        return true
    }

    /// The automatic entry point, called when a refresh fails with an expired login. Every guard lives
    /// here so the policy is testable without a container.
    func signInAutomatically() {
        guard isAutoEnabled() else { return }
        guard !phase.isInFlight else { return }
        guard !autoAttemptedThisSession else {
            AppLog.debug(LogTag.auth("llmcenter"), "auto sign-in already attempted this session; leaving it to the card button")
            return
        }
        // A refresh that fails during launch would open a browser before the user has even seen the
        // dashboard. Wait until the app has completed a refresh pass first.
        guard hasCompletedFirstRefresh() else {
            AppLog.debug(LogTag.auth("llmcenter"), "auto sign-in skipped: no refresh pass has completed yet")
            return
        }
        autoAttemptedThisSession = true
        AppLog.info(LogTag.auth("llmcenter"), "auto sign-in starting after an expired-login refresh failure")
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

    /// 48 hex characters from the system CSPRNG. A sign-in nonce must be unguessable, and a
    /// `SecRandomCopyBytes` failure is surfaced as an error rather than falling back to a weaker source.
    nonisolated static func makeState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            AppLog.error(LogTag.auth("llmcenter"), "SecRandomCopyBytes failed; cannot generate a sign-in state")
            throw LLMCenterSignInError.stateUnavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func run() async {
        defer { pollTask = nil }
        do {
            let api = try await resolveAPIBaseURL()
            let state = try makeState()
            let session = try await client.createSession(api: api, state: state)
            guard !Task.isCancelled else { return }

            phase = .awaitingBrowser
            AppLog.info(
                LogTag.auth("llmcenter"),
                "opening the authorization page: \(LogRedaction.redactURL(session.authorizeURL.absoluteString))"
            )
            openURL(session.authorizeURL)

            let token = try await awaitAuthorization(api: api, session: session)
            guard !Task.isCancelled else { return }

            try await loadOffMainActor { [authStore] in
                try authStore.save(webToken: token.webToken, appCode: token.appCode, api: api)
            }
            AppLog.info(LogTag.auth("llmcenter"), "sign-in complete; saved a new token to the llmctl config")

            await refreshAfterSignIn()
            guard !Task.isCancelled else { return }
            phase = .succeeded
        } catch is CancellationError {
            // `cancel()` already reset the phase.
        } catch {
            AppLog.error(LogTag.auth("llmcenter"), "sign-in failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func resolveAPIBaseURL() async throws -> String {
        let api = try await loadOffMainActor { [authStore] in try authStore.loadAPIBaseURL() }
        guard let api else {
            // Nothing on disk names a server, so there is nothing to authorize against. This is the
            // never-logged-in case, not an expiry — the CLI has to run once to record the host.
            throw LLMCenterSignInError.apiBaseURLUnknown
        }
        return api
    }

    /// Polls until the server hands back a token, the user is refused, or the session expires. Transient
    /// transport failures are retried a bounded number of times — the poll is a safe GET, and a single
    /// dropped request should not discard an authorization the user already completed in the browser.
    private func awaitAuthorization(
        api: String, session: LLMCenterAuthSession
    ) async throws -> (webToken: String, appCode: String?) {
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
            case .authorized(let webToken, let appCode):
                return (webToken, appCode)
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
