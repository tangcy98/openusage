import Foundation

/// USD conversion rates for the non-USD currencies OpenUsage prices in — today only CNY (LLM Center).
///
/// The Total Spend ring sums every provider's spend into one figure, and that figure is denominated in
/// dollars because every other provider bills in dollars. A CNY provider therefore needs a rate before
/// it can join the ring at all; without one its ¥ would be added as if it were $, inflating both the
/// center total and every other provider's share.
///
/// Design mirrors `ModelPricingStore`: a bundled fallback so a fresh, offline launch still converts,
/// a disk cache in Application Support, and a daily background refresh. `usdPerCNY()` never blocks on
/// the network — it serves the freshest rate on hand and revalidates behind the user's back.
actor ExchangeRateStore {
    static let shared = ExchangeRateStore()

    /// Refetch this long after the last success. FX moves slowly enough at this precision that a
    /// daily rate is plenty, and the endpoint is a free unauthenticated service worth being gentle to.
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// Retry a failed fetch after this long, so an offline machine doesn't log once a minute.
    private static let failureRetryInterval: TimeInterval = 60 * 60

    /// The rate used before the first successful fetch, and whenever the feed is unreachable and no
    /// cache exists. Deliberately a plausible round number rather than a precise one: it exists so the
    /// ring shows a roughly-right share instead of nothing, and the UI labels any converted total as an
    /// estimate regardless of which rate produced it.
    static let fallbackUSDPerCNY = 0.14

    private struct Cache: Codable {
        var usdPerCNY: Double
        var fetchedAt: Date
    }

    private let http: any HTTPClient
    private let cacheFile: URL
    private let now: @Sendable () -> Date
    private let sourceURL: URL

    private var loaded = false
    private var cache: Cache?
    private var failedAt: Date?
    private var refreshTask: Task<Void, Never>?

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        cacheFile: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sourceURL: URL = URL(string: "https://api.exchangerate.fun/latest?base=USD&symbols=CNY")!
    ) {
        self.http = http
        self.cacheFile = cacheFile ?? Self.defaultCacheFile
        self.now = now
        self.sourceURL = sourceURL
    }

    private static var defaultCacheFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenUsage/exchange_rates.json")
    }

    /// Dollars per yuan. Kicks a background refresh when the cached rate is due; the refreshed rate is
    /// picked up by the next call.
    func usdPerCNY() -> Double {
        loadIfNeeded()
        if refreshTask == nil, isDue {
            refreshTask = Task { await self.refresh() }
        }
        return cache?.usdPerCNY ?? Self.fallbackUSDPerCNY
    }

    /// Runs a due fetch to completion — for tests and deterministic refresh points.
    func refreshNow() async {
        loadIfNeeded()
        if refreshTask == nil {
            refreshTask = Task { await self.refresh() }
        }
        await refreshTask?.value
    }

    private var isDue: Bool {
        if let failedAt, now().timeIntervalSince(failedAt) < Self.failureRetryInterval { return false }
        guard let cache else { return true }
        return now().timeIntervalSince(cache.fetchedAt) >= Self.refreshInterval
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheFile) else { return }
        do {
            cache = try JSONDecoder().decode(Cache.self, from: data)
        } catch {
            AppLog.warn(.config, "cached exchange rate unreadable, using fallback: \(error.localizedDescription)")
        }
    }

    private func refresh() async {
        defer { refreshTask = nil }
        do {
            let response = try await http.send(HTTPRequest(method: "GET", url: sourceURL, timeout: 20))
            guard response.statusCode == 200 else { throw ExchangeRateError.httpStatus(response.statusCode) }
            // `{"base":"USD","rates":{"CNY":6.7517}}` — yuan per dollar, so invert for our direction.
            guard let object = ProviderParse.jsonObject(response.body),
                  let rates = object["rates"] as? [String: Any],
                  let cnyPerUSD = ProviderParse.number(rates["CNY"]), cnyPerUSD > 0
            else { throw ExchangeRateError.invalidResponse }
            let updated = Cache(usdPerCNY: 1 / cnyPerUSD, fetchedAt: now())
            cache = updated
            failedAt = nil
            write(updated)
            AppLog.info(.config, "exchange rate refreshed (1 CNY = \(updated.usdPerCNY) USD)")
        } catch {
            failedAt = now()
            AppLog.warn(.config, "exchange rate refresh failed, keeping cached rate: \(error.localizedDescription)")
        }
    }

    private func write(_ cache: Cache) {
        do {
            try FileManager.default.createDirectory(
                at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
        } catch {
            AppLog.warn(.config, "could not persist exchange rate: \(error.localizedDescription)")
        }
    }
}

private enum ExchangeRateError: Error, LocalizedError {
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        case .invalidResponse: return "no CNY rate in the response"
        }
    }
}
