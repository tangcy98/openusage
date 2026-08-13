import Foundation

/// One in-flight CLI authorization, as the server describes it. Every field comes from the server's own
/// response — in particular `authorizeURL`, whose host differs from the API host, so it is used verbatim
/// and never reassembled from parts.
struct LLMCenterAuthSession: Sendable, Equatable {
    var state: String
    var authorizeURL: URL
    var expiresIn: TimeInterval
    var pollInterval: Duration
}

/// The state of one poll. `authorized` is decided by a non-empty `webToken` and nothing else — see
/// `LLMCenterAuthClient.poll`.
enum LLMCenterAuthPoll: Sendable, Equatable {
    case pending
    case authorized(webToken: String, appCode: String?)
    /// Terminal refusal: an error code, or a status we don't recognize with no token attached.
    case rejected(code: String?)
}

enum LLMCenterSignInError: Error, LocalizedError, Equatable {
    case sessionFailed(detail: String)
    case authorizeURLInvalid
    case pollFailed(code: String?)
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
        case .timedOut:
            return "Sign-in timed out. Click Sign In to start over."
        case .stateUnavailable:
            return "Couldn't generate a secure sign-in request. Try again."
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

    /// `POST {api}/llm/api/cli/auth/session` with a caller-generated `state`. Deliberately unauthenticated:
    /// the whole point is to run when the stored token is dead.
    func createSession(api: String, state: String) async throws -> LLMCenterAuthSession {
        let payload = try? JSONSerialization.data(withJSONObject: ["state": state])
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
            pollInterval: Self.pollInterval(fromMilliseconds: ProviderParse.number(data["pollIntervalMs"]))
        )
    }

    /// `GET {api}/llm/api/cli/auth/poll?state=…`. The verb matters: the same path answers a POST with
    /// HTTP 500, so this must stay a GET with the state in the query string.
    ///
    /// Success is "there is a non-empty `webToken`", never a status string. A completed authorization
    /// was observed sending `status: "completed"` (2026-08-13), but branching on that literal would risk
    /// discarding a token we were actually handed if the server ever words it differently — the token's
    /// presence is the fact that matters. Anything else without a token is treated as a refusal rather
    /// than as "keep waiting".
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
        if let token = (data["webToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let appCode = (data["appCode"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            AppLog.debug(
                LogTag.auth("llmcenter"),
                "poll returned a token; status=\(data["status"] as? String ?? "<none>") "
                    + "keys=\(data.keys.sorted().joined(separator: ","))"
            )
            return .authorized(webToken: token, appCode: appCode)
        }
        let status = (data["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "pending" { return .pending }
        return .rejected(code: status?.nilIfEmpty)
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
