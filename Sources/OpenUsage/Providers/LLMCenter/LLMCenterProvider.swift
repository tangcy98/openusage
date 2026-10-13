import Foundation

@MainActor
final class LLMCenterProvider: ProviderRuntime {
    let provider = Provider(
        id: "llmcenter",
        displayName: "LLMCenter",
        icon: .providerMark("llmcenter"),
        links: [
            ProviderLink(label: "Usage", url: "https://llm-center.modelbest.co/usage")
        ]
    )

    let authStore: LLMCenterAuthStore
    let usageClient: LLMCenterUsageClient
    let tokenRefresher: LLMCenterTokenRefresher
    let now: @Sendable () -> Date

    init(
        authStore: LLMCenterAuthStore = LLMCenterAuthStore(),
        usageClient: LLMCenterUsageClient = LLMCenterUsageClient(),
        authClient: LLMCenterAuthClient = LLMCenterAuthClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.tokenRefresher = LLMCenterTokenRefresher(authStore: authStore, client: authClient, now: now)
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            // Today and Yesterday feed the Total Spend ring (converted from CNY at the daily rate);
            // This Month has no matching ring period, so it stays a plain meter.
            .boundedYuan(id: "llmcenter.today", provider: provider, title: "Today",
                         limit: 225, limitNoun: "soft quota", isUsagePeriod: true)
                .contributingToTotalSpend(),
            .boundedYuan(id: "llmcenter.month", provider: provider, title: "This Month",
                         limit: 7000, limitNoun: "quota", isUsagePeriod: true)
                .exportingLimit("month", unit: "cny"),
            .combined(id: "llmcenter.yesterday", provider: provider, title: "Yesterday",
                      isUsagePeriod: true)
                .contributingToTotalSpend(),
            .usageTrend(provider: provider)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: the stored login file. A broken file is a credential-access
        // problem, not "no login" — but the probe stays boolean, so only the file's presence counts.
        await loadOffMainActor { [authStore] in
            guard let auth = try? authStore.loadAuth() else { return false }
            return !auth.webToken.isEmpty
        }
    }

    func refresh() async -> ProviderSnapshot {
        let auth: LLMCenterAuth?
        do {
            auth = try await loadOffMainActor { [authStore] in try authStore.loadAuth() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard var auth else {
            return ProviderSnapshot.error(provider: provider, error: LLMCenterAuthError.notLoggedIn)
        }

        // The access token only lives about an hour, so renew it from the refresh token before it lapses
        // instead of sending the user back to the browser. A failed renewal isn't fatal yet — the current
        // token may still have minutes left — so the outcome is remembered and judged only if the server
        // actually rejects the token.
        var renewal: LLMCenterRefreshResult?
        if tokenRefresher.needsRenewal(auth) {
            let result = await tokenRefresher.refresh(auth)
            if case .refreshed(let renewed) = result { auth = renewed }
            renewal = result
        }

        let calendar = Calendar.current
        let now = now()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today

        // The monthly quota is the required, official anchor. A failure here surfaces as a provider
        // error; the day-level statistics below are best-effort (a failure skips that row, the meter
        // stays).
        let quota: LLMCenterQuota
        do {
            do {
                quota = try await fetchQuota(auth: auth)
            } catch LLMCenterUsageError.invalidToken where renewal == nil && auth.refresh != nil {
                // The server rejected a token we thought was fine (no readable expiry, clock skew, or
                // revoked early): spend the refresh token once and retry.
                let result = await tokenRefresher.refresh(auth)
                renewal = result
                guard case .refreshed(let renewed) = result else { throw LLMCenterUsageError.invalidToken }
                auth = renewed
                quota = try await fetchQuota(auth: auth)
            }
        } catch LLMCenterUsageError.invalidToken where renewal == .unavailable {
            // The token was rejected and renewing it failed for a reason that isn't the login's fault, so
            // "sign in again" would be the wrong advice — and would pop a browser for a network blip.
            return ProviderSnapshot.error(provider: provider, error: LLMCenterUsageError.connectionFailed)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: Self.classify(error))
        }

        // Official daily statistics + the per-model breakdown rows, both best-effort.
        let todayStats = try? await usageClient.fetchStatistics(api: auth.apiBaseURL, token: auth.webToken, from: today, to: today)
        let yesterdayStats = try? await usageClient.fetchStatistics(api: auth.apiBaseURL, token: auth.webToken, from: yesterday, to: yesterday)
        let details = (try? await usageClient.fetchModelDetails(api: auth.apiBaseURL, token: auth.webToken, from: monthStart, to: now)) ?? []

        let dayKey: (Date) -> String = { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
        let todayKey = dayKey(now)
        let yesterdayKey = dayKey(yesterday)
        let monthPrefix = String(todayKey.prefix(7))

        var lines: [MetricLine] = []

        if let monthLine = LLMCenterUsageMapper.quotaLine(
            spent: quota.spent,
            quota: quota.monthlyQuota,
            breakdown: LLMCenterUsageMapper.breakdown(
                rows: details, matching: { $0.hasPrefix(monthPrefix) },
                totalCost: quota.spent, totalTokens: 0
            )
        ) {
            lines.append(monthLine)
        }

        if let todayStats {
            lines.append(LLMCenterUsageMapper.todayLine(
                cost: todayStats.cost,
                softLimit: LLMCenterUsageMapper.softDailyQuota(monthlyQuota: quota.monthlyQuota, now: now, calendar: calendar),
                breakdown: LLMCenterUsageMapper.breakdown(
                    rows: details, matching: { $0 == todayKey },
                    totalCost: todayStats.cost, totalTokens: todayStats.tokens
                )
            ))
        }

        if let yesterdayStats {
            lines.append(LLMCenterUsageMapper.yesterdayLine(
                cost: yesterdayStats.cost, tokens: yesterdayStats.tokens,
                breakdown: LLMCenterUsageMapper.breakdown(
                    rows: details, matching: { $0 == yesterdayKey },
                    totalCost: yesterdayStats.cost, totalTokens: yesterdayStats.tokens
                )
            ))
        }

        if let trendLine = LLMCenterUsageMapper.trendLine(rows: details, now: now, calendar: calendar) {
            lines.append(trendLine)
        }

        guard !lines.isEmpty else {
            return ProviderSnapshot.error(provider: provider, error: LLMCenterUsageError.connectionFailed)
        }
        return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now)
    }

    private func fetchQuota(auth: LLMCenterAuth) async throws -> LLMCenterQuota {
        let department = try await usageClient.fetchMyDepartment(api: auth.apiBaseURL, token: auth.webToken)
        let members = try await usageClient.fetchDepartmentMembers(
            api: auth.apiBaseURL, token: auth.webToken, deptId: department.deptId
        )
        guard let member = members.first(where: { $0["userId"] as? String == department.userId }),
              let monthlyQuota = ProviderParse.number(member["effectiveQuota"]), monthlyQuota > 0,
              let spent = ProviderParse.number(member["spentAmount"])
        else {
            throw LLMCenterUsageError.invalidResponse
        }
        return LLMCenterQuota(monthlyQuota: monthlyQuota, spent: max(0, spent))
    }

    private static func classify(_ error: Error) -> LLMCenterUsageError {
        if case LLMCenterUsageError.invalidToken = error { return .invalidToken }
        return error as? LLMCenterUsageError ?? .connectionFailed
    }
}

private struct LLMCenterQuota {
    var monthlyQuota: Double
    var spent: Double
}