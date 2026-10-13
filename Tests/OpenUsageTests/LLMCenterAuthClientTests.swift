import XCTest
@testable import OpenUsage

// MARK: - LLMCenterAuthClientTests

/// LLMCenter's browser-authorization protocol, which OpenUsage drives itself so signing in never needs
/// a terminal. See docs/research/llm-center-api.md — the shapes asserted here were captured from real
/// authorizations, and a couple of them (GET-not-POST on poll, `codeChallenge` as the protocol marker,
/// code-then-exchange rather than a ready-made token) are the kind of detail that silently breaks the
/// flow if it regresses.
final class LLMCenterAuthClientTests: XCTestCase {
    private let api = "https://api.example.test"

    private static func pkce() throws -> LLMCenterPKCE {
        try LLMCenterPKCE.generate()
    }

    private static func sessionResponse(
        state: String,
        authorizeURL: String = "https://portal.example.test/cli-auth?state=abc"
    ) -> HTTPResponse {
        let body = """
        {"code":0,"data":{"state":"\(state)","authorizeUrl":"\(authorizeURL)","expiresIn":300,"pollIntervalMs":1000,\
        "tokenEndpoint":"https://iam.example.test/api/admin/oauth2/token","clientId":"client-1",\
        "redirectUri":"https://api.example.test/auth/callback"}}
        """
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    func testSessionRequestCarriesPKCEChallenge() async throws {
        let http = RoutingHTTPClient { _ in Self.sessionResponse(state: "abc") }
        let client = LLMCenterAuthClient(http: http)
        let pkce = try Self.pkce()

        _ = try await client.createSession(api: api, state: "abc", pkce: pkce, redirectUri: "https://api.example.test/auth/callback")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "\(api)/llm/api/cli/auth/session")
        XCTAssertNil(request.headers["Authorization"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(body["state"], "abc")
        // The challenge is the protocol marker: a body with only `state` is answered with the bogus
        // "only llmctl 0.2.12+ is supported" error.
        XCTAssertEqual(body["codeChallenge"], pkce.challenge)
        XCTAssertEqual(body["oidcRedirectUri"], "https://api.example.test/auth/callback")
        XCTAssertNil(body["codeVerifier"], "the verifier must never be sent when opening the session")
    }

    func testPKCEChallengeIsS256OfVerifier() throws {
        let pkce = try Self.pkce()
        XCTAssertEqual(pkce.challenge, LLMCenterPKCE.challenge(for: pkce.verifier))
        // base64url, no padding, 32 bytes -> 43 chars (RFC 7636's minimum length).
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertFalse(pkce.verifier.contains("+"))
        XCTAssertFalse(pkce.verifier.contains("/"))
        XCTAssertFalse(pkce.verifier.contains("="))
        XCTAssertEqual(pkce.challenge.count, 43)
    }

    func testSessionUsesServerAuthorizeURLVerbatim() async throws {
        // The authorize page lives on a DIFFERENT host than the API. Reassembling it from the API base
        // would send the user to a URL that doesn't exist.
        let http = RoutingHTTPClient { _ in
            Self.sessionResponse(state: "abc", authorizeURL: "https://elsewhere.example.test/cli-auth?state=abc")
        }

        let session = try await LLMCenterAuthClient(http: http).createSession(
            api: api, state: "abc", pkce: try Self.pkce(), redirectUri: nil
        )

        XCTAssertEqual(session.authorizeURL.absoluteString, "https://elsewhere.example.test/cli-auth?state=abc")
        XCTAssertEqual(session.expiresIn, 300)
        XCTAssertEqual(session.pollInterval, .seconds(1))
    }

    func testSessionCarriesPKCEAndTokenEndpoint() async throws {
        let http = RoutingHTTPClient { _ in Self.sessionResponse(state: "abc") }
        let pkce = try Self.pkce()

        let session = try await LLMCenterAuthClient(http: http).createSession(
            api: api, state: "abc", pkce: pkce, redirectUri: nil
        )

        XCTAssertEqual(session.pkce, pkce)
        XCTAssertEqual(session.tokenEndpoint?.absoluteString, "https://iam.example.test/api/admin/oauth2/token")
        XCTAssertEqual(session.clientId, "client-1")
        XCTAssertEqual(session.redirectUri, "https://api.example.test/auth/callback")
    }

    func testSessionRejectsUnparsableAuthorizeURL() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"authorizeUrl":"not a url"}}"#.utf8))
        }

        let pkce = try Self.pkce()
        await XCTAssertThrowsErrorAsync(
            try await LLMCenterAuthClient(http: http).createSession(api: self.api, state: "abc", pkce: pkce, redirectUri: nil)
        ) { error in
            XCTAssertEqual(error as? LLMCenterSignInError, .authorizeURLInvalid)
        }
    }

    func testSessionRejectsStateMismatch() async throws {
        let http = RoutingHTTPClient { _ in Self.sessionResponse(state: "someone-else") }

        let pkce = try Self.pkce()
        await XCTAssertThrowsErrorAsync(
            try await LLMCenterAuthClient(http: http).createSession(api: self.api, state: "abc", pkce: pkce, redirectUri: nil)
        ) { error in
            guard case .sessionFailed = error as? LLMCenterSignInError else {
                return XCTFail("expected sessionFailed, got \(error)")
            }
        }
    }

    func testSessionClampsPollInterval() async throws {
        for (millis, expected) in [(5, Duration.milliseconds(500)), (999_999, Duration.seconds(5))] {
            let http = RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"code":0,"data":{"authorizeUrl":"https://p.example.test/x","pollIntervalMs":\(millis)}}
                """.utf8))
            }
            let session = try await LLMCenterAuthClient(http: http).createSession(
                api: api, state: "abc", pkce: try Self.pkce(), redirectUri: nil
            )
            XCTAssertEqual(session.pollInterval, expected)
        }
    }

    func testPollUsesGETWithStateQuery() async throws {
        // Regression guard: the same path answers a POST with HTTP 500.
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"status":"pending"}}"#.utf8))
        }

        _ = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.url.absoluteString, "\(api)/llm/api/cli/auth/poll?state=abc")
    }

    func testPollPendingWhenNoAuthorizationCode() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"status":"pending","authorizationCode":null}}"#.utf8))
        }

        let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

        XCTAssertEqual(result, .pending)
    }

    func testPollSucceedsOnNonEmptyAuthorizationCodeRegardlessOfStatus() async throws {
        // The completion-state status literal was never observed against the real server, so a code in
        // hand wins no matter what the status says. Matching on the status instead would risk throwing
        // away a code we were actually handed.
        for status in ["\"success\"", "\"authorized\"", "\"done\"", "\"\"", "null"] {
            let http = RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"code":0,"data":{"status":\(status),"authorizationCode":"code-1"}}
                """.utf8))
            }

            let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

            XCTAssertEqual(result, .authorized(code: "code-1"), "status \(status)")
        }
    }

    func testPollSurfacesRelayedOAuthError() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("""
            {"code":0,"data":{"status":"failed","authorizationCode":null,"error":"access_denied",\
            "errorDescription":"user denied the request"}}
            """.utf8))
        }

        let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

        XCTAssertEqual(result, .rejected(code: "user denied the request"))
    }

    func testPollTreatsUnknownStatusWithoutCodeAsFailure() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"status":"revoked","authorizationCode":null}}"#.utf8))
        }

        let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

        XCTAssertEqual(result, .rejected(code: "revoked"))
    }

    func testPollSurfacesProtocolErrorCodes() async throws {
        for code in ["E_TIMEOUT", "E_RATE_LIMITED", "E_AUTH_REQUIRED"] {
            let http = RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"\#(code)","message":"nope"}"#.utf8))
            }

            let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

            XCTAssertEqual(result, .rejected(code: code))
        }
    }

    func testPollRejectsNon2xx() async throws {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 503, headers: [:], body: Data()) }

        let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

        XCTAssertEqual(result, .rejected(code: "HTTP 503"))
    }

    func testPollEmptyStringCodeIsNotSuccess() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"status":"pending","authorizationCode":"  "}}"#.utf8))
        }

        let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

        XCTAssertEqual(result, .pending)
    }

    // MARK: - Token exchange

    private func makeSession(
        tokenEndpoint: String? = "https://iam.example.test/api/admin/oauth2/token"
    ) throws -> LLMCenterAuthSession {
        LLMCenterAuthSession(
            state: "abc",
            authorizeURL: URL(string: "https://p.example.test/x")!,
            expiresIn: 300,
            pollInterval: .seconds(1),
            pkce: try Self.pkce(),
            tokenEndpoint: tokenEndpoint.flatMap(URL.init(string:)),
            clientId: "client-1",
            redirectUri: "https://api.example.test/auth/callback"
        )
    }

    func testExchangePostsFormEncodedCodeAndVerifier() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"web_token":"tok-new","app_code":"app-1"}"#.utf8))
        }
        let session = try makeSession()

        let token = try await LLMCenterAuthClient(http: http).exchangeAuthorizationCode(
            session: session, code: "code-1"
        )

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://iam.example.test/api/admin/oauth2/token")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.body), encoding: .utf8))
        XCTAssertTrue(body.contains("grant_type=authorization_code"), body)
        XCTAssertTrue(body.contains("code=code-1"), body)
        XCTAssertTrue(body.contains("code_verifier=\(session.pkce.verifier)"), body)
        XCTAssertTrue(body.contains("client_id=client-1"), body)
        XCTAssertTrue(body.contains("redirect_uri="), body)
        XCTAssertEqual(token.webToken, "tok-new")
        XCTAssertEqual(token.appCode, "app-1")
    }

    func testExchangeAcceptsOAuthAccessTokenName() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"tok-oauth","token_type":"Bearer"}"#.utf8))
        }

        let token = try await LLMCenterAuthClient(http: http).exchangeAuthorizationCode(
            session: try makeSession(), code: "code-1"
        )

        XCTAssertEqual(token.webToken, "tok-oauth")
        XCTAssertNil(token.appCode)
    }

    func testExchangeWithoutTokenEndpointFails() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"web_token":"tok"}"#.utf8))
        }

        await XCTAssertThrowsErrorAsync(
            try await LLMCenterAuthClient(http: http).exchangeAuthorizationCode(
                session: try self.makeSession(tokenEndpoint: nil), code: "code-1"
            )
        ) { error in
            guard case .tokenExchangeFailed = error as? LLMCenterSignInError else {
                return XCTFail("expected tokenExchangeFailed, got \(error)")
            }
        }
    }

    func testExchangeWithoutTokenFails() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"token_type":"Bearer"}"#.utf8))
        }

        await XCTAssertThrowsErrorAsync(
            try await LLMCenterAuthClient(http: http).exchangeAuthorizationCode(
                session: try self.makeSession(), code: "code-1"
            )
        ) { error in
            guard case .tokenExchangeFailed = error as? LLMCenterSignInError else {
                return XCTFail("expected tokenExchangeFailed, got \(error)")
            }
        }
    }

    func testFormEncodePercentEncodesReservedCharacters() {
        let encoded = LLMCenterAuthClient.formEncode(["redirect_uri": "https://a.example.test/auth/callback?x=1&y=2"])
        XCTAssertEqual(encoded, "redirect_uri=https%3A%2F%2Fa.example.test%2Fauth%2Fcallback%3Fx%3D1%26y%3D2")
    }
}

// MARK: - Helpers

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
