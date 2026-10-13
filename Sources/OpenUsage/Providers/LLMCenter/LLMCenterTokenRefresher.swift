import Foundation

enum LLMCenterRefreshResult: Equatable, Sendable {
    /// A usable login: either freshly renewed, or one another process (`llmctl`) renewed first.
    case refreshed(LLMCenterAuth)
    /// The refresh token is gone, dead, or was never stored — only a new browser sign-in recovers.
    case rejected
    /// The token endpoint couldn't be reached or answered badly; the stored login may still be fine.
    case unavailable
}

/// Renews the short-lived LLMCenter access token from the stored refresh token, so an hour-long token
/// doesn't mean an hourly trip to the browser. The access token expires after about an hour regardless of
/// who asked; what the refresh token buys is not having to ask the user again.
struct LLMCenterTokenRefresher: Sendable {
    /// Renew this long before expiry, so a request in flight when the clock runs out doesn't 401.
    static let renewalBuffer: TimeInterval = 5 * 60

    var authStore: LLMCenterAuthStore
    var client: LLMCenterAuthClient
    var now: @Sendable () -> Date

    /// True when the token is within the buffer of its expiry and there's a refresh token to spend. A
    /// token with no readable expiry is left alone and renewed reactively, after the server says 401.
    func needsRenewal(_ auth: LLMCenterAuth) -> Bool {
        guard auth.refresh != nil, let expiresAt = auth.tokenExpiresAt else { return false }
        return expiresAt.timeIntervalSince(now()) <= Self.renewalBuffer
    }

    func refresh(_ auth: LLMCenterAuth) async -> LLMCenterRefreshResult {
        guard let grant = auth.refresh else { return .rejected }

        let tokens: LLMCenterTokenSet
        do {
            tokens = try await client.refreshTokens(grant: grant)
        } catch let LLMCenterRefreshError.rejected(detail) {
            return await recoverFromRejection(auth: auth, grant: grant, detail: detail)
        } catch let LLMCenterRefreshError.unavailable(detail) {
            AppLog.warn(LogTag.auth("llmcenter"), "token refresh unavailable: \(detail)")
            return .unavailable
        } catch {
            AppLog.warn(LogTag.auth("llmcenter"), "token refresh failed: \(error.localizedDescription)")
            return .unavailable
        }

        var renewed = auth
        renewed.webToken = tokens.webToken
        renewed.refresh = LLMCenterRefreshGrant(
            refreshToken: tokens.refreshToken ?? grant.refreshToken,
            tokenEndpoint: grant.tokenEndpoint,
            clientId: grant.clientId
        )
        renewed.tokenExpiresAt = tokens.expiresIn.map { now().addingTimeInterval($0) }
            ?? ProviderParse.jwtPayload(tokens.webToken)?["exp"].flatMap(ProviderParse.number)
                .map { Date(timeIntervalSince1970: $0) }

        // Fail loudly, but keep going: the renewed token works for this session even when the write
        // doesn't land. A rotated refresh token that couldn't be persisted is the costly case — the
        // one on disk is spent — and this line is the only trace of why the next refresh is rejected.
        do {
            try await loadOffMainActor { [authStore, now] in
                try authStore.save(tokens, api: auth.apiBaseURL, source: .refresh, now: now())
            }
        } catch {
            AppLog.error(
                LogTag.auth("llmcenter"),
                "renewed the token but couldn't persist it; using it for this session only: \(error.localizedDescription)"
            )
        }
        AppLog.info(LogTag.auth("llmcenter"), "access token renewed from the refresh token")
        return .refreshed(renewed)
    }

    /// A rejected refresh token isn't always dead: `llmctl` shares this file and may have spent it a moment
    /// ago, rotating a new pair onto disk. Re-reading before giving up turns that race into a success
    /// instead of a needless browser sign-in.
    private func recoverFromRejection(
        auth: LLMCenterAuth, grant: LLMCenterRefreshGrant, detail: String
    ) async -> LLMCenterRefreshResult {
        let onDisk = try? await loadOffMainActor { [authStore] in try authStore.loadAuth() }
        if let onDisk, onDisk.webToken != auth.webToken || onDisk.refresh?.refreshToken != grant.refreshToken {
            AppLog.info(LogTag.auth("llmcenter"), "refresh token was rejected but the login on disk has changed; using that")
            return .refreshed(onDisk)
        }
        AppLog.warn(LogTag.auth("llmcenter"), "refresh token rejected (\(detail)); a new sign-in is needed")
        return .rejected
    }
}
