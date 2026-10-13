import Foundation

/// The LLMCenter credential stored on this machine: the API base URL plus the Rosefinch bearer token
/// used on every request. OpenUsage reads and writes this file directly — it never asks the user to
/// paste a token and never shells out to anything.
struct LLMCenterAuth: Hashable, Sendable {
    var apiBaseURL: String
    var webToken: String
    /// What it takes to renew `webToken` without the browser; `nil` for a login that stored none (an
    /// older `llmctl`, or a sign-in made before the app kept refresh tokens).
    var refresh: LLMCenterRefreshGrant?
    /// When `webToken` stops working: the JWT's own `exp`, else the file's `token_expires_at`. `nil` when
    /// neither is readable, in which case the token is only renewed after the server rejects it.
    var tokenExpiresAt: Date?
}

/// The refresh token plus the OIDC client identity and endpoint it must be redeemed at. All three come
/// from the server's sign-in response and are stored beside the token (the `llmctl` CLI writes the same
/// `oidc_*` keys), so renewal never has to guess a deployment's endpoints.
struct LLMCenterRefreshGrant: Hashable, Sendable {
    var refreshToken: String
    var tokenEndpoint: URL
    var clientId: String
}

/// The OIDC endpoints a sign-in session was opened against, persisted so a later refresh can reach them.
struct LLMCenterOIDCMetadata: Equatable, Sendable {
    var tokenEndpoint: URL? = nil
    var clientId: String? = nil
    var redirectUri: String? = nil
}

enum LLMCenterAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable(detail: String)
    case saveFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not signed in to LLMCenter. Click Sign In on the LLMCenter card."
        case .credentialsUnreadable:
            return "Couldn't read the LLMCenter login. Check ~/Library/Application Support/llmctl/config.json, then refresh."
        case .saveFailed:
            return "Couldn't save the LLMCenter login to disk. Check the file's permissions, then try again."
        }
    }
}

/// Reads and writes `~/Library/Application Support/llmctl/config.json`, which holds
/// `{ "api": "<base URL>", "web_token": "<token>" }`. The presence and validity of the file is the
/// first-run signal (`hasLocalCredentials`), and `refresh()` re-reads it so a rotated token is picked up
/// on the next cycle. `LLMCenterSignInService` writes it after an in-app authorization.
///
/// The path is shared with the `llmctl` CLI, which stores its own keys (`access_key`, `model`, `env`)
/// in the same file. OpenUsage does not depend on that tool in any way, but it does not clobber its
/// keys either: writes are read-modify-write (see `save`), so both can use one login.

struct LLMCenterAuthStore: Sendable {
    var files: TextFileAccessing
    var configPath: String

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        configPath: String? = nil
    ) {
        self.files = files
        self.configPath = configPath ?? Self.defaultConfigPath()
    }

    static func defaultConfigPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("llmctl/config.json").path
    }

    /// The signed-in auth, or `nil` when the user has not logged in. A present file that can't be read
    /// or parsed throws `credentialsUnreadable` so broken storage is never mistaken for logout; an
    /// absent file is the normal "not logged in" `nil`.
    func loadAuth() throws -> LLMCenterAuth? {
        guard let object = try loadObject() else { return nil }
        guard let api = Self.text(object["api"]),
              let webToken = Self.text(object["web_token"])
        else { return nil }
        // A host recorded before it was retired is rewritten here rather than at each call site, so
        // every request — usage and sign-in alike — talks to the live deployment.
        return LLMCenterAuth(
            apiBaseURL: LLMCenterHost.migrated(api),
            webToken: webToken,
            refresh: Self.refreshGrant(from: object),
            tokenExpiresAt: Self.expiry(of: webToken, object: object)
        )
    }

    /// Only a complete, https-only set counts: a refresh token with no known endpoint can't be redeemed,
    /// and a non-https endpoint would put the refresh token on the wire in the clear.
    private static func refreshGrant(from object: [String: Any]) -> LLMCenterRefreshGrant? {
        guard let refreshToken = text(object["refresh_token"]),
              let clientId = text(object["oidc_client_id"]),
              let endpoint = text(object["oidc_token_endpoint"]).flatMap(LLMCenterAuthClient.httpsURL)
        else { return nil }
        return LLMCenterRefreshGrant(refreshToken: refreshToken, tokenEndpoint: endpoint, clientId: clientId)
    }

    /// The token's own `exp` wins: it is what the server enforces. `token_expires_at` is a copy that
    /// goes stale whenever something other than the CLI replaces `web_token`, so it's only the fallback
    /// for an opaque (non-JWT) token.
    private static func expiry(of webToken: String, object: [String: Any]) -> Date? {
        if let exp = ProviderParse.jwtPayload(webToken)?["exp"].flatMap(ProviderParse.number) {
            return Date(timeIntervalSince1970: exp)
        }
        return ProviderParse.number(object["token_expires_at"]).map { Date(timeIntervalSince1970: $0) }
    }

    /// The API base URL to authorize against, which `loadAuth()` can't supply once the token is gone.
    /// Falls back to `LLMCenterHost.live` when nothing on disk names a server, so a machine that has
    /// never signed in can still start the flow — a recorded host always wins, since it may name a
    /// deployment we don't know about.
    func loadAPIBaseURL() throws -> String {
        guard let object = try loadObject() else { return LLMCenterHost.live }
        return Self.text(object["api"]).map(LLMCenterHost.migrated) ?? LLMCenterHost.live
    }

    /// Writes a freshly authorized token back to disk. Read-modify-write: every key already in the file
    /// survives untouched — the `llmctl` CLI shares this path and also stores `access_key`, `model`, and
    /// `env` here, and clobbering those would break it for no reason. `api` is only filled in when
    /// missing — or when the recorded host is one we know is retired, since leaving a dead address on
    /// disk would keep anything else reading the file broken even though the app has recovered.
    /// `app_code` is only written when the authorization actually returned one, so an existing value is
    /// never replaced with an invented one.
    ///
    /// The token's companion keys (`refresh_token`, `token_expires_at`, `oidc_*`) are written together
    /// with it, because `llmctl` reads the same ones: leaving an old refresh token beside a new access
    /// token would let the CLI "renew" with a stale pair and overwrite the login we just saved.
    func save(
        _ tokens: LLMCenterTokenSet,
        api: String,
        source: SaveSource,
        now: Date = Date()
    ) throws {
        // A file we can't parse must not silently lose the other keys, but it also must not trap the
        // user: the whole point of in-app sign-in is recovering a broken login. So a corrupt file is
        // rebuilt from scratch and the loss is logged loudly rather than passed over.
        var object: [String: Any]
        do {
            object = try loadObject() ?? [:]
        } catch {
            AppLog.error(
                LogTag.auth("llmcenter"),
                "config.json is unparsable; rewriting it from scratch, any other keys in it will be lost: \(error.localizedDescription)"
            )
            object = [:]
        }
        object["web_token"] = tokens.webToken
        Self.applyTokenCompanions(to: &object, tokens: tokens, source: source, now: now)
        if let recorded = Self.text(object["api"]) {
            // The one case where an existing value is replaced: a host confirmed dead. `api` reached
            // this method already migrated (sign-in read it through `loadAPIBaseURL`), so writing it
            // back repairs a file that would otherwise stay pointed at a dead address.
            if LLMCenterHost.isRetired(recorded) {
                object["api"] = LLMCenterHost.migrated(recorded)
            }
        } else {
            object["api"] = api
        }
        if let appCode = tokens.appCode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            object["app_code"] = appCode
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw LLMCenterAuthError.saveFailed(detail: "config.json could not be encoded as UTF-8")
            }
            // `LocalTextFileAccessor.writeText` publishes through a 0600 temp file + rename, so the
            // token is never briefly world-readable and a crash can't leave a truncated config.
            try files.writeText(configPath, text)
        } catch let error as LLMCenterAuthError {
            throw error
        } catch {
            throw LLMCenterAuthError.saveFailed(detail: error.localizedDescription)
        }
    }

    /// Where a saved token came from, which decides what happens to the refresh token already on disk.
    enum SaveSource: Equatable, Sendable {
        /// A fresh browser authorization. The server's answer replaces everything: a response without a
        /// refresh token must not leave the previous login's one behind.
        case signIn(LLMCenterOIDCMetadata)
        /// A refresh-token grant. Servers that don't rotate omit `refresh_token` from the answer, in which
        /// case the one on disk is still the live one and is kept.
        case refresh
    }

    private static func applyTokenCompanions(
        to object: inout [String: Any], tokens: LLMCenterTokenSet, source: SaveSource, now: Date
    ) {
        if let refreshToken = tokens.refreshToken {
            object["refresh_token"] = refreshToken
        } else if case .signIn = source {
            object.removeValue(forKey: "refresh_token")
        }
        if case .signIn(let oidc) = source {
            if let endpoint = oidc.tokenEndpoint { object["oidc_token_endpoint"] = endpoint.absoluteString }
            if let clientId = oidc.clientId { object["oidc_client_id"] = clientId }
            if let redirectUri = oidc.redirectUri { object["oidc_redirect_uri"] = redirectUri }
        }
        // The server's stated lifetime, else what the JWT says; neither known means no stale copy stays.
        let expiresAt = tokens.expiresIn.map { now.addingTimeInterval($0) }
            ?? ProviderParse.jwtPayload(tokens.webToken)?["exp"].flatMap(ProviderParse.number)
                .map { Date(timeIntervalSince1970: $0) }
        if let expiresAt {
            object["token_expires_at"] = Int(expiresAt.timeIntervalSince1970)
        } else {
            object.removeValue(forKey: "token_expires_at")
        }
    }

    /// The parsed config, or `nil` when the file is absent. Shared by every accessor so a broken file is
    /// classified identically no matter which field the caller wanted.
    private func loadObject() throws -> [String: Any]? {
        let text: String?
        do {
            text = try files.readTextIfPresent(configPath)
        } catch {
            throw LLMCenterAuthError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let text else { return nil }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw LLMCenterAuthError.credentialsUnreadable(detail: "config.json is not valid JSON")
        }
        return object
    }

    private static func text(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
