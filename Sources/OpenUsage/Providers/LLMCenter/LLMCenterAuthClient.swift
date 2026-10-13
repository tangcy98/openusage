import CryptoKit
import Foundation

/// The single-use PKCE pair for one authorization attempt. The verifier never leaves this machine until
/// the token exchange; only its SHA-256 challenge is sent when the session is opened, so an intercepted
/// session cannot be redeemed without the verifier.
struct LLMCenterPKCE: Sendable, Equatable {
    var verifier: String
    var challenge: String

    /// 32 random bytes, base64url-encoded without padding (`code_verifier`). RFC 7636 allows 43–128
    /// characters; 32 bytes encodes to exactly 43, the minimum, and is well inside the CSPRNG's range.
    static func generate() throws -> LLMCenterPKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LLMCenterSignInError.stateUnavailable
        }
        let verifier = base64URL(Data(bytes))
        return LLMCenterPKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))` — the S256 method the server advertises in `authorizeUrl`.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Standard base64's `+`, `/`, and `=` are not URL-safe and would be mangled as query values, so
    /// PKCE requires the base64url alphabet without padding.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One in-flight CLI authorization, as the server describes it. Every field comes from the server's own
/// response — in particular `authorizeURL`, whose host differs from the API host, so it is used verbatim
/// and never reassembled from parts.
struct LLMCenterAuthSession: Sendable, Equatable {
    var state: String
    var authorizeURL: URL
    var expiresIn: TimeInterval
    var pollInterval: Duration
    /// The PKCE verifier this attempt was opened with. Held so the token exchange can prove it owns the
    /// `codeChallenge` that `createSession` submitted.
    var pkce: LLMCenterPKCE
    /// Where to redeem the authorization code, and the client identity to redeem it as. Both are handed
    /// to us by the server rather than hardcoded, since they belong to the deployment.
    var tokenEndpoint: URL?
    var clientId: String?
    var redirectUri: String?
}

/// What a token endpoint hands back, for both the authorization-code and the refresh-token grant.
/// `webToken` is a short-lived (about an hour) access token; `refreshToken` is what lets the app trade it
/// for a new one without sending the user back to the browser.
struct LLMCenterTokenSet: Sendable, Equatable {
    var webToken: String
    var appCode: String? = nil
    var refreshToken: String? = nil
    /// Seconds the access token stays valid, as the server stated it.
    var expiresIn: TimeInterval? = nil
}

/// Why a refresh-token grant did not yield a token. The split decides what the user sees: `rejected`
/// means the refresh token is dead and only a new browser sign-in helps; `unavailable` is a network or
/// server hiccup where the stored login may still be fine.
enum LLMCenterRefreshError: Error, Equatable {
    case rejected(detail: String)
    case unavailable(detail: String)
}

/// The state of one poll. Success is "the server handed us an authorization code": since the OIDC
/// migration the poll relays a code to exchange, not a ready-made token — see `LLMCenterAuthClient.poll`.
enum LLMCenterAuthPoll: Sendable, Equatable {
    case pending
    /// The browser step finished; redeem this code at the token endpoint with the PKCE verifier.
    case authorized(code: String)
    /// Terminal refusal: an error code, or a status we don't recognize with no code attached.
    case rejected(code: String?)
}

enum LLMCenterSignInError: Error, LocalizedError, Equatable {
    case sessionFailed(detail: String)
    case authorizeURLInvalid
    case pollFailed(code: String?)
    case tokenExchangeFailed(detail: String)
    case timedOut
    case stateUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionFailed:
            return "Couldn't start the LLMCenter sign-in. Try again in a moment."
        case .authorizeURLInvalid:
            return "LLMCenter returned an unusable sign-in link. Try again in a moment."
        case .pollFailed(let code):
            if let code, !code.isEmpty {
                return "LLMCenter declined the sign-in (\(code)). Try again."
            }
            return "LLMCenter declined the sign-in. Try again."
        case .tokenExchangeFailed:
            return "LLMCenter authorized the sign-in but couldn't complete it. Try again in a moment."
        case .timedOut:
            return "Sign-in timed out. Click Sign In to start over."
        case .stateUnavailable:
            return "Couldn't generate a secure sign-in request. Try again."
        }
    }

    /// The underlying cause, for the log only. `errorDescription` deliberately says the same friendly
    /// sentence for every `sessionFailed`, which hides whether the transport failed, the server answered
    /// an unexpected status, or it refused the request with a business error code. Never shown to the user.
    var diagnosticDetail: String? {
        switch self {
        case .sessionFailed(let detail): detail
        case .pollFailed(let code): code
        case .tokenExchangeFailed(let detail): detail
        case .authorizeURLInvalid, .timedOut, .stateUnavailable: nil
        }
    }
}

/// Drives LLMCenter's three-step CLI authorization protocol: open a session, send the user to the
/// browser, then poll until the server hands back a token. None of the three steps needs an existing
/// credential — which is what lets it serve as both the first sign-in and the recovery path for an
/// expired one. See docs/research/llm-center-api.md.
struct LLMCenterAuthClient: Sendable {
    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Server-side clamps on the poll cadence. The server currently asks for 1s; the bounds keep a
    /// surprising value from either hammering the endpoint or stalling the flow past the user's patience.
    private static let minimumPollInterval: Duration = .milliseconds(500)
    private static let maximumPollInterval: Duration = .seconds(5)
    private static let defaultExpiresIn: TimeInterval = 300

    /// `POST {api}/llm/api/cli/auth/session` with a caller-generated `state` and PKCE challenge.
    /// Deliberately unauthenticated: the whole point is to run when the stored token is dead.
    ///
    /// The `codeChallenge` is what identifies this as the current protocol. A body carrying only `state`
    /// is answered with a bogus "only llmctl 0.2.12 or newer is supported" business error — that message
    /// describes the protocol version, not an installed CLI.
    func createSession(api: String, state: String, pkce: LLMCenterPKCE, redirectUri: String?) async throws -> LLMCenterAuthSession {
        var payloadObject: [String: Any] = ["state": state, "codeChallenge": pkce.challenge]
        if let redirectUri = redirectUri?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            payloadObject["oidcRedirectUri"] = redirectUri
        }
        let payload = try? JSONSerialization.data(withJSONObject: payloadObject)
        guard let payload, let url = Self.url(api: api, path: "llm/api/cli/auth/session") else {
            throw LLMCenterSignInError.sessionFailed(detail: "invalid API base URL")
        }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "POST",
                url: url,
                headers: ["Content-Type": "application/json", "Accept": "application/json"],
                body: payload,
                timeout: 20
            ))
        } catch {
            throw LLMCenterSignInError.sessionFailed(detail: error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LLMCenterSignInError.sessionFailed(detail: "HTTP \(response.statusCode)")
        }
        guard let object = ProviderParse.jsonObject(response.body),
              ProviderParse.number(object["code"]) == 0,
              let data = object["data"] as? [String: Any]
        else {
            // `URLSessionHTTPClient` previews a body only for status >= 400; a refusal arrives as HTTP 200
            // with a non-zero code, so this is the sole place the server's explanation gets logged (redacted).
            AppLog.warn(
                .http,
                "llmcenter auth/session refused: \(LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self)))"
            )
            throw LLMCenterSignInError.sessionFailed(detail: "unexpected session response")
        }
        guard let rawURL = (data["authorizeUrl"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              let authorizeURL = URL(string: rawURL),
              authorizeURL.scheme?.lowercased() == "https"
        else {
            throw LLMCenterSignInError.authorizeURLInvalid
        }
        // A mismatched state means this reply belongs to someone else's session; polling it would be
        // meaningless at best.
        if let echoed = (data["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
           echoed != state {
            throw LLMCenterSignInError.sessionFailed(detail: "session state did not match the request")
        }
        let expiresIn = ProviderParse.number(data["expiresIn"]).map { max(1, $0) } ?? Self.defaultExpiresIn
        return LLMCenterAuthSession(
            state: state,
            authorizeURL: authorizeURL,
            expiresIn: expiresIn,
            pollInterval: Self.pollInterval(fromMilliseconds: ProviderParse.number(data["pollIntervalMs"])),
            pkce: pkce,
            tokenEndpoint: (data["tokenEndpoint"] as? String).flatMap(Self.httpsURL),
            clientId: (data["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            redirectUri: (data["redirectUri"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    /// `GET {api}/llm/api/cli/auth/poll?state=…`. The verb matters: the same path answers a POST with
    /// HTTP 500, so this must stay a GET with the state in the query string.
    ///
    /// Success is "the server handed us a non-empty `authorizationCode`", never a status string — the
    /// code's presence is the fact that matters, and branching on a status literal would risk discarding
    /// a code we were actually handed. Anything else without a code is a refusal, not "keep waiting".
    func poll(api: String, state: String) async throws -> LLMCenterAuthPoll {
        guard var components = Self.url(api: api, path: "llm/api/cli/auth/poll")
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        else {
            throw LLMCenterSignInError.sessionFailed(detail: "invalid API base URL")
        }
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        guard let url = components.url else {
            throw LLMCenterSignInError.sessionFailed(detail: "invalid poll URL")
        }
        let response = try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Accept": "application/json"],
            timeout: 15
        ))
        guard (200..<300).contains(response.statusCode) else {
            return .rejected(code: "HTTP \(response.statusCode)")
        }
        guard let object = ProviderParse.jsonObject(response.body) else {
            return .rejected(code: nil)
        }
        guard ProviderParse.number(object["code"]) == 0, let data = object["data"] as? [String: Any] else {
            let code = (object["code"] as? String) ?? (object["message"] as? String)
            return .rejected(code: code)
        }
        if let code = (data["authorizationCode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            AppLog.debug(
                LogTag.auth("llmcenter"),
                "poll returned an authorization code; status=\(data["status"] as? String ?? "<none>")"
            )
            return .authorized(code: code)
        }
        // The server can also relay a terminal OAuth error instead of a code; surface it rather than polling on.
        if let error = (data["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let description = (data["errorDescription"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return .rejected(code: description ?? error)
        }
        let status = (data["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "pending" { return .pending }
        return .rejected(code: status?.nilIfEmpty)
    }

    /// `POST {tokenEndpoint}` — the OIDC token exchange that turns the relayed `authorizationCode` into
    /// the `web_token` this app and the `llmctl` CLI store in `config.json`.
    ///
    /// The `code_verifier` is what proves this process started the session: the server compares its hash
    /// against the `codeChallenge` submitted when the session was created. Form-encoded, not JSON —
    /// that is what the OAuth 2.0 token endpoint requires.
    func exchangeAuthorizationCode(
        session: LLMCenterAuthSession, code: String
    ) async throws -> LLMCenterTokenSet {
        guard let tokenEndpoint = session.tokenEndpoint else {
            throw LLMCenterSignInError.tokenExchangeFailed(detail: "server did not provide a token endpoint")
        }
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": session.pkce.verifier
        ]
        if let clientId = session.clientId { fields["client_id"] = clientId }
        if let redirectUri = session.redirectUri { fields["redirect_uri"] = redirectUri }

        let response: HTTPResponse
        do {
            response = try await postTokenRequest(to: tokenEndpoint, fields: fields)
        } catch {
            throw LLMCenterSignInError.tokenExchangeFailed(detail: error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(
                .http,
                "llmcenter token exchange rejected: \(LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self)))"
            )
            throw LLMCenterSignInError.tokenExchangeFailed(detail: "HTTP \(response.statusCode)")
        }
        guard let object = ProviderParse.jsonObject(response.body) else {
            throw LLMCenterSignInError.tokenExchangeFailed(detail: "unexpected token response")
        }
        guard let tokens = Self.tokenSet(from: object) else {
            throw LLMCenterSignInError.tokenExchangeFailed(detail: "token response contained no token")
        }
        return tokens
    }

    /// `POST {tokenEndpoint}` with `grant_type=refresh_token` — trades the stored refresh token for a new
    /// access token with no browser step. Unlike every other call here it does use a credential, so the
    /// failure split matters: a 4xx means the refresh token itself is dead (`invalid_grant` when it expired,
    /// was revoked, or was already spent by a rotation), while timeouts, 429 and 5xx say nothing about the
    /// login and must not send the user through a needless sign-in.
    func refreshTokens(grant: LLMCenterRefreshGrant) async throws -> LLMCenterTokenSet {
        let response: HTTPResponse
        do {
            response = try await postTokenRequest(to: grant.tokenEndpoint, fields: [
                "grant_type": "refresh_token",
                "refresh_token": grant.refreshToken,
                "client_id": grant.clientId
            ])
        } catch {
            throw LLMCenterRefreshError.unavailable(detail: error.localizedDescription)
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 408, 429, 500...:
            throw LLMCenterRefreshError.unavailable(detail: "HTTP \(response.statusCode)")
        default:
            AppLog.warn(
                .http,
                "llmcenter token refresh rejected: \(LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self)))"
            )
            throw LLMCenterRefreshError.rejected(detail: "HTTP \(response.statusCode)")
        }
        guard let object = ProviderParse.jsonObject(response.body),
              let tokens = Self.tokenSet(from: object)
        else {
            throw LLMCenterRefreshError.unavailable(detail: "unexpected token response")
        }
        return tokens
    }

    private func postTokenRequest(to endpoint: URL, fields: [String: String]) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "POST",
            url: endpoint,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json"
            ],
            body: Data(Self.formEncode(fields).utf8),
            timeout: 20
        ))
    }

    /// Reads the flat OAuth token response. `web_token` is the field the shared config stores;
    /// `access_token` is the OAuth name for the same value, accepted too so a naming change on the server
    /// can't strand the login.
    private static func tokenSet(from object: [String: Any]) -> LLMCenterTokenSet? {
        guard let token = firstNonEmpty(object, keys: ["web_token", "webToken", "access_token", "accessToken"]) else {
            return nil
        }
        return LLMCenterTokenSet(
            webToken: token,
            appCode: firstNonEmpty(object, keys: ["app_code", "appCode"]),
            refreshToken: firstNonEmpty(object, keys: ["refresh_token", "refreshToken"]),
            expiresIn: ProviderParse.number(object["expires_in"]).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private static func firstNonEmpty(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return value
            }
        }
        return nil
    }

    /// Percent-encodes an OAuth token request body. Values are RFC 3986 unreserved-only, which is what
    /// form encoding requires — blank values are kept so a required-but-empty parameter is still sent.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    static func httpsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }

    private static func url(api: String, path: String) -> URL? {
        URL(string: api.trimmingCharacters(in: .whitespacesAndNewlines))?.appendingPathComponent(path)
    }

    private static func pollInterval(fromMilliseconds milliseconds: Double?) -> Duration {
        guard let milliseconds, milliseconds > 0 else { return .seconds(1) }
        let requested = Duration.milliseconds(Int(milliseconds.rounded()))
        return min(max(requested, minimumPollInterval), maximumPollInterval)
    }
}
