import XCTest
@testable import OpenUsage

private let configPath = "/tmp/fake/llmctl/config.json"
private let tokenEndpoint = "https://iam.example.test/api/admin/oauth2/token"
private let clock = Date(timeIntervalSince1970: 1_790_000_000)

/// An unsigned JWT whose payload carries `exp`, the only claim the app reads from the access token.
private func jwt(expiringAt exp: Date, tag: String = "a") -> String {
    func b64(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return [b64(["alg": "none"]), b64(["exp": Int(exp.timeIntervalSince1970), "tag": tag]), "sig"].joined(separator: ".")
}

private func config(
    token: String, refresh: String? = "refresh-1", staleExpiry: Int? = nil, extra: String = ""
) -> String {
    var fields = [
        #""api":"https://llm-center.modelbest.co""#,
        #""web_token":"\#(token)""#,
        #""oidc_client_id":"client-1""#,
        #""oidc_token_endpoint":"\#(tokenEndpoint)""#
    ]
    if let refresh { fields.append(#""refresh_token":"\#(refresh)""#) }
    if let staleExpiry { fields.append(#""token_expires_at":\#(staleExpiry)"#) }
    if !extra.isEmpty { fields.append(extra) }
    return "{\(fields.joined(separator: ","))}"
}

private func savedObject(_ files: FakeFiles) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any])
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

private func refreshedResponse(token: String, refresh: String? = "refresh-2") -> HTTPResponse {
    var object: [String: Any] = ["web_token": token, "expires_in": 3600]
    if let refresh { object["refresh_token"] = refresh }
    return HTTPResponse(statusCode: 200, headers: [:], body: json(object))
}

// MARK: - Client

final class LLMCenterRefreshClientTests: XCTestCase {
    private let grant = LLMCenterRefreshGrant(
        refreshToken: "refresh-1", tokenEndpoint: URL(string: tokenEndpoint)!, clientId: "client-1"
    )

    func testRefreshPostsTheRefreshGrantAndReadsTheRotatedPair() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: json([
                "web_token": "tok-2", "refresh_token": "refresh-2", "expires_in": 3600
            ]))
        }

        let tokens = try await LLMCenterAuthClient(http: http).refreshTokens(grant: grant)

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, tokenEndpoint)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.body), encoding: .utf8))
        XCTAssertTrue(body.contains("grant_type=refresh_token"), body)
        XCTAssertTrue(body.contains("refresh_token=refresh-1"), body)
        XCTAssertTrue(body.contains("client_id=client-1"), body)
        XCTAssertEqual(tokens, LLMCenterTokenSet(webToken: "tok-2", refreshToken: "refresh-2", expiresIn: 3600))
    }

    func testRefreshAcceptsAnAnswerWithoutARotatedRefreshToken() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: json(["access_token": "tok-2"]))
        }

        let tokens = try await LLMCenterAuthClient(http: http).refreshTokens(grant: grant)

        XCTAssertEqual(tokens.webToken, "tok-2")
        XCTAssertNil(tokens.refreshToken)
    }

    /// 4xx means the refresh token itself is dead; only a browser sign-in helps.
    func testRefresh4xxIsRejected() async {
        for status in [400, 401, 403] {
            let http = RoutingHTTPClient { _ in
                HTTPResponse(statusCode: status, headers: [:], body: json(["error": "invalid_grant"]))
            }
            await XCTAssertThrowsErrorAsync(try await LLMCenterAuthClient(http: http).refreshTokens(grant: self.grant)) { error in
                guard case .rejected = error as? LLMCenterRefreshError else {
                    return XCTFail("HTTP \(status): expected rejected, got \(error)")
                }
            }
        }
    }

    /// Timeouts, throttling and server errors say nothing about the login, so they must never read as
    /// "sign in again".
    func testRefreshTransientFailuresAreUnavailable() async {
        for status in [408, 429, 500, 503] {
            let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: status, headers: [:], body: Data()) }
            await XCTAssertThrowsErrorAsync(try await LLMCenterAuthClient(http: http).refreshTokens(grant: self.grant)) { error in
                guard case .unavailable = error as? LLMCenterRefreshError else {
                    return XCTFail("HTTP \(status): expected unavailable, got \(error)")
                }
            }
        }
    }

    func testRefreshTransportFailureIsUnavailable() async {
        let http = RoutingHTTPClient { _ in throw URLError(.notConnectedToInternet) }

        await XCTAssertThrowsErrorAsync(try await LLMCenterAuthClient(http: http).refreshTokens(grant: self.grant)) { error in
            guard case .unavailable = error as? LLMCenterRefreshError else {
                return XCTFail("expected unavailable, got \(error)")
            }
        }
    }

    func testRefreshAnswerWithoutATokenIsUnavailable() async {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: json(["token_type": "Bearer"])) }

        await XCTAssertThrowsErrorAsync(try await LLMCenterAuthClient(http: http).refreshTokens(grant: self.grant)) { error in
            guard case .unavailable = error as? LLMCenterRefreshError else {
                return XCTFail("expected unavailable, got \(error)")
            }
        }
    }

    func testExchangeKeepsTheRefreshTokenAndLifetime() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: json([
                "web_token": "tok-1", "refresh_token": "refresh-1", "expires_in": "3600"
            ]))
        }
        let session = LLMCenterAuthSession(
            state: "s", authorizeURL: URL(string: "https://p.example.test/x")!, expiresIn: 300,
            pollInterval: .seconds(1), pkce: try LLMCenterPKCE.generate(),
            tokenEndpoint: URL(string: tokenEndpoint), clientId: "client-1", redirectUri: nil
        )

        let tokens = try await LLMCenterAuthClient(http: http).exchangeAuthorizationCode(session: session, code: "c")

        XCTAssertEqual(tokens.refreshToken, "refresh-1")
        XCTAssertEqual(tokens.expiresIn, 3600)
    }
}

// MARK: - Store

final class LLMCenterRefreshStoreTests: XCTestCase {
    func testLoadAuthReadsTheRefreshGrantAndTheJWTExpiry() throws {
        let exp = clock.addingTimeInterval(1800)
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: config(token: jwt(expiringAt: exp))]), configPath: configPath
        )

        let auth = try XCTUnwrap(store.loadAuth())

        XCTAssertEqual(auth.refresh, LLMCenterRefreshGrant(
            refreshToken: "refresh-1", tokenEndpoint: URL(string: tokenEndpoint)!, clientId: "client-1"
        ))
        XCTAssertEqual(auth.tokenExpiresAt, Date(timeIntervalSince1970: exp.timeIntervalSince1970.rounded()))
    }

    /// `token_expires_at` goes stale whenever something other than the CLI swaps `web_token`; the token's
    /// own `exp` is what the server enforces, so it must win.
    func testTheTokensOwnExpiryBeatsAStaleTokenExpiresAt() throws {
        let exp = clock.addingTimeInterval(3000)
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: config(token: jwt(expiringAt: exp), staleExpiry: 1_000_000)]),
            configPath: configPath
        )

        let expiresAt = try XCTUnwrap(store.loadAuth()?.tokenExpiresAt)

        XCTAssertEqual(expiresAt.timeIntervalSince1970, exp.timeIntervalSince1970, accuracy: 1)
    }

    func testAnOpaqueTokenFallsBackToTokenExpiresAt() throws {
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: config(token: "opaque", staleExpiry: 1_790_003_600)]), configPath: configPath
        )

        XCTAssertEqual(try store.loadAuth()?.tokenExpiresAt, Date(timeIntervalSince1970: 1_790_003_600))
    }

    func testAnIncompleteOrInsecureGrantIsIgnored() throws {
        let noEndpoint = #"{"api":"https://x.test","web_token":"t","refresh_token":"r","oidc_client_id":"c"}"#
        let insecure = #"{"api":"https://x.test","web_token":"t","refresh_token":"r","oidc_client_id":"c","oidc_token_endpoint":"http://iam.example.test/token"}"#
        for text in [noEndpoint, insecure] {
            let store = LLMCenterAuthStore(files: FakeFiles([configPath: text]), configPath: configPath)
            XCTAssertNil(try store.loadAuth()?.refresh, text)
        }
    }

    func testSignInWritesTheWholeCredentialAndKeepsTheCLIsOwnKeys() throws {
        let files = FakeFiles([configPath: config(token: "old", refresh: "stale", staleExpiry: 1, extra: #""access_key":"ak-1""#)])
        let store = LLMCenterAuthStore(files: files, configPath: configPath)
        let oidc = LLMCenterOIDCMetadata(
            tokenEndpoint: URL(string: "https://iam.new.test/token"), clientId: "client-2", redirectUri: "https://x.test/cb"
        )

        try store.save(
            LLMCenterTokenSet(webToken: "tok-new", refreshToken: "refresh-new", expiresIn: 3600),
            api: "https://llm-center.modelbest.co", source: .signIn(oidc), now: clock
        )

        let saved = try savedObject(files)
        XCTAssertEqual(saved["web_token"] as? String, "tok-new")
        XCTAssertEqual(saved["refresh_token"] as? String, "refresh-new")
        XCTAssertEqual(saved["token_expires_at"] as? Int, Int(clock.timeIntervalSince1970) + 3600)
        XCTAssertEqual(saved["oidc_token_endpoint"] as? String, "https://iam.new.test/token")
        XCTAssertEqual(saved["oidc_client_id"] as? String, "client-2")
        XCTAssertEqual(saved["oidc_redirect_uri"] as? String, "https://x.test/cb")
        XCTAssertEqual(saved["access_key"] as? String, "ak-1")
    }

    /// A new login that carries no refresh token must not leave the previous login's one beside the new
    /// access token: `llmctl` would "renew" with the stale pair and overwrite what was just saved.
    func testSignInWithoutARefreshTokenClearsTheStaleOne() throws {
        let files = FakeFiles([configPath: config(token: "old", refresh: "stale", staleExpiry: 1)])
        let store = LLMCenterAuthStore(files: files, configPath: configPath)

        try store.save(
            LLMCenterTokenSet(webToken: "tok-new"), api: "https://llm-center.modelbest.co",
            source: .signIn(LLMCenterOIDCMetadata()), now: clock
        )

        let saved = try savedObject(files)
        XCTAssertNil(saved["refresh_token"])
        XCTAssertNil(saved["token_expires_at"], "an expiry that can't be known must not be left stale")
    }

    func testRefreshWithoutARotatedTokenKeepsTheOneOnDisk() throws {
        let files = FakeFiles([configPath: config(token: "old", refresh: "refresh-1")])
        let store = LLMCenterAuthStore(files: files, configPath: configPath)

        try store.save(
            LLMCenterTokenSet(webToken: "tok-2", expiresIn: 3600),
            api: "https://llm-center.modelbest.co", source: .refresh, now: clock
        )

        let saved = try savedObject(files)
        XCTAssertEqual(saved["web_token"] as? String, "tok-2")
        XCTAssertEqual(saved["refresh_token"] as? String, "refresh-1")
        XCTAssertEqual(saved["oidc_client_id"] as? String, "client-1")
    }

    func testRefreshWithARotatedTokenReplacesIt() throws {
        let files = FakeFiles([configPath: config(token: "old", refresh: "refresh-1")])
        let store = LLMCenterAuthStore(files: files, configPath: configPath)

        try store.save(
            LLMCenterTokenSet(webToken: "tok-2", refreshToken: "refresh-2"),
            api: "https://llm-center.modelbest.co", source: .refresh, now: clock
        )

        XCTAssertEqual(try savedObject(files)["refresh_token"] as? String, "refresh-2")
    }
}

// MARK: - Provider

@MainActor
final class LLMCenterTokenRefreshProviderTests: XCTestCase {
    private let myUserId = "user-1"

    /// Serves the usage endpoints only to the access token currently "valid" on the server, and the
    /// refresh grant per `onRefresh`. Records which bearer each usage call carried.
    private final class Server: @unchecked Sendable {
        var validToken: String
        var refreshCalls = 0
        var usageBearers: [String] = []
        var onRefresh: @Sendable (Server) -> HTTPResponse = { _ in HTTPResponse(statusCode: 500, headers: [:], body: Data()) }

        init(validToken: String) { self.validToken = validToken }
    }

    private func makeProvider(files: FakeFiles, server: Server) -> LLMCenterProvider {
        let userId = myUserId
        let dept = json(["code": 0, "data": ["userId": userId, "deptId": 16, "deptName": "t"]])
        let members = json(["code": 0, "data": [
            ["userId": userId, "effectiveQuota": 7000.0, "spentAmount": 150.0]
        ]])
        let stats = json(["code": 0, "data": ["totalCost": 1.0, "totalTokens": 10, "totalCalls": 1]])
        let details = json(["code": 0, "data": ["detailList": []]])
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString == tokenEndpoint {
                server.refreshCalls += 1
                return server.onRefresh(server)
            }
            let bearer = request.headers["Authorization"] ?? ""
            server.usageBearers.append(bearer)
            guard bearer == "Bearer \(server.validToken)" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            let path = request.url.path
            let body = path.hasSuffix("/department/my") ? dept
                : path.hasSuffix("/members") ? members
                : path.hasSuffix("/statistics") ? stats : details
            return HTTPResponse(statusCode: 200, headers: [:], body: body)
        }
        return LLMCenterProvider(
            authStore: LLMCenterAuthStore(files: files, configPath: configPath),
            usageClient: LLMCenterUsageClient(http: http),
            authClient: LLMCenterAuthClient(http: http),
            now: { clock }
        )
    }

    func testAnExpiringTokenIsRenewedBeforeTheUsageCallsAndPersisted() async throws {
        let old = jwt(expiringAt: clock.addingTimeInterval(60), tag: "old")
        let renewed = jwt(expiringAt: clock.addingTimeInterval(3600), tag: "new")
        let files = FakeFiles([configPath: config(token: old)])
        let server = Server(validToken: renewed)
        server.onRefresh = { _ in refreshedResponse(token: renewed) }

        let snapshot = await makeProvider(files: files, server: server).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(server.refreshCalls, 1)
        XCTAssertTrue(server.usageBearers.allSatisfy { $0 == "Bearer \(renewed)" }, "no call may carry the old token")
        let saved = try savedObject(files)
        XCTAssertEqual(saved["web_token"] as? String, renewed)
        XCTAssertEqual(saved["refresh_token"] as? String, "refresh-2")
    }

    func testAComfortablyValidTokenIsNotRenewed() async {
        let token = jwt(expiringAt: clock.addingTimeInterval(1800))
        let server = Server(validToken: token)

        let snapshot = await makeProvider(files: FakeFiles([configPath: config(token: token)]), server: server).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(server.refreshCalls, 0)
    }

    /// A token whose expiry can't be read is only renewed once the server turns it down — and the call
    /// that was turned down is retried with the new token rather than failing the refresh.
    func testAServerRejectionRenewsOnceAndRetries() async throws {
        let renewed = jwt(expiringAt: clock.addingTimeInterval(3600), tag: "new")
        let files = FakeFiles([configPath: config(token: "opaque-old")])
        let server = Server(validToken: renewed)
        server.onRefresh = { _ in refreshedResponse(token: renewed) }

        let snapshot = await makeProvider(files: files, server: server).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(server.refreshCalls, 1)
        XCTAssertEqual(try savedObject(files)["web_token"] as? String, renewed)
    }

    func testADeadRefreshTokenReportsExpiredSoSignInTakesOver() async {
        let old = jwt(expiringAt: clock.addingTimeInterval(-60))
        let server = Server(validToken: "something-else")
        server.onRefresh = { _ in HTTPResponse(statusCode: 400, headers: [:], body: json(["error": "invalid_grant"])) }

        let snapshot = await makeProvider(files: FakeFiles([configPath: config(token: old)]), server: server).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(server.refreshCalls, 1, "a dead refresh token is spent once per refresh, not again on the 401")
    }

    /// A network blip while renewing must not look like an expired login: that would open a browser
    /// for something the user can't fix by signing in.
    func testATransientRenewalFailureIsNotReportedAsExpired() async {
        let old = jwt(expiringAt: clock.addingTimeInterval(-60))
        let server = Server(validToken: "something-else")
        server.onRefresh = { _ in HTTPResponse(statusCode: 503, headers: [:], body: Data()) }

        let snapshot = await makeProvider(files: FakeFiles([configPath: config(token: old)]), server: server).refresh()

        XCTAssertNotEqual(snapshot.errorCategory, .authExpired)
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    /// `llmctl` shares the file. If it spent our refresh token a moment ago, the new pair is already on
    /// disk — use it instead of sending the user to the browser.
    func testARejectionIsRecoveredWhenAnotherProcessAlreadyRenewed() async throws {
        let old = jwt(expiringAt: clock.addingTimeInterval(-60), tag: "old")
        let theirs = jwt(expiringAt: clock.addingTimeInterval(3600), tag: "theirs")
        let files = FakeFiles([configPath: config(token: old)])
        let server = Server(validToken: theirs)
        server.onRefresh = { _ in
            files.files[configPath] = config(token: theirs, refresh: "refresh-theirs")
            return HTTPResponse(statusCode: 400, headers: [:], body: json(["error": "invalid_grant"]))
        }

        let snapshot = await makeProvider(files: files, server: server).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(try savedObject(files)["refresh_token"] as? String, "refresh-theirs", "their login is left as they wrote it")
    }

    func testALoginWithoutARefreshTokenBehavesAsBefore() async {
        let old = jwt(expiringAt: clock.addingTimeInterval(-60))
        let server = Server(validToken: "something-else")

        let snapshot = await makeProvider(
            files: FakeFiles([configPath: config(token: old, refresh: nil)]), server: server
        ).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(server.refreshCalls, 0)
    }
}
