import Foundation

/// The LLMCenter API host: the live default, plus rewrites for hosts known to be retired.
///
/// A login records the host it was made against, and nothing revises it afterwards — so a config left
/// over from a deployment that has since been shut down keeps every metric failing, and the failure
/// looks like a server problem rather than a stale address.
///
/// So the rewrite is a migration, not a fallback: only hosts confirmed dead are replaced, by the one
/// host confirmed live, and every rewrite is logged. An unrecognized host is passed through untouched —
/// a deployment we've never heard of is the user's business, not ours to redirect.
enum LLMCenterHost {
    /// Where sign-in goes when nothing on disk names a server — the first-run case. Confirmed live
    /// (see `retiredHosts`), and the same host every retired one migrates to.
    static let live = "https://llm-center.modelbest.co"

    /// Retired host → its replacement. Measured 2026-08-09:
    /// - `llm-center.modelbest.cn` — the public-internet entry point, now shut down; a Huawei Cloud
    ///   WAF answers every path with HTTP 418.
    /// - `llm-center.ali.modelbest.co` — 404 on every path including the root.
    /// - `llm-center.modelbest.co` — live; unauthenticated 401, and all four endpoints answer 200
    ///   with a valid token.
    private static let retiredHosts: [String: String] = [
        "llm-center.modelbest.cn": "llm-center.modelbest.co",
        "llm-center.ali.modelbest.cn": "llm-center.modelbest.co",
        "llm-center.ali.modelbest.co": "llm-center.modelbest.co"
    ]

    /// The API base URL to actually call. Returns `api` unchanged unless its host is a known-dead one,
    /// in which case the live host is substituted and the substitution is logged loudly — the user's
    /// `config.json` is stale and that is worth knowing, even though the app recovers on its own.
    static func migrated(_ api: String) -> String {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let host = components.host,
              let replacement = retiredHosts[host.lowercased()]
        else { return trimmed }
        components.host = replacement
        guard let migrated = components.string else { return trimmed }
        AppLog.warn(
            LogTag.auth("llmcenter"),
            "config.json records the retired host \(host); using \(replacement) instead"
        )
        return migrated
    }

    /// Whether `api` names a host we know is dead — the signal for rewriting the stored value rather
    /// than only the in-memory one.
    static func isRetired(_ api: String) -> Bool {
        guard let host = URLComponents(string: api.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        else { return false }
        return retiredHosts[host.lowercased()] != nil
    }
}
