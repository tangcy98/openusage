import XCTest
@testable import OpenUsage

// MARK: - LLMCenterAuthClientTests

/// LLMCenter's browser-authorization protocol, which OpenUsage drives itself so signing in never needs
/// a terminal. See docs/research/llm-center-api.md — the shapes asserted here were captured from real
/// authorizations, and a couple of them (GET-not-POST on poll, token-not-status as the success signal)
/// are the kind of detail that silently breaks the flow if it regresses.
final class LLMCenterAuthClientTests: XCTestCase {
    private let api = "https://api.example.test"

    private static func sessionResponse(
        state: String,
        authorizeURL: String = "https://portal.example.test/cli-auth?state=abc"
    ) -> HTTPResponse {
        let body = """
        {"code":0,"data":{"state":"\(state)","authorizeUrl":"\(authorizeURL)","expiresIn":300,"pollIntervalMs":1000}}
        """
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    func testSessionRequestShapeAndBody() async throws {
        let http = RoutingHTTPClient { _ in Self.sessionResponse(state: "abc") }
        let client = LLMCenterAuthClient(http: http)

        _ = try await client.createSession(api: api, state: "abc")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "\(api)/llm/api/cli/auth/session")
        XCTAssertNil(request.headers["Authorization"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(body, ["state": "abc"])
    }

    func testSessionUsesServerAuthorizeURLVerbatim() async throws {
        // The authorize page lives on a DIFFERENT host than the API. Reassembling it from the API base
        // would send the user to a URL that doesn't exist.
        let http = RoutingHTTPClient { _ in
            Self.sessionResponse(state: "abc", authorizeURL: "https://elsewhere.example.test/cli-auth?state=abc")
        }

        let session = try await LLMCenterAuthClient(http: http).createSession(api: api, state: "abc")

        XCTAssertEqual(session.authorizeURL.absoluteString, "https://elsewhere.example.test/cli-auth?state=abc")
        XCTAssertEqual(session.expiresIn, 300)
        XCTAssertEqual(session.pollInterval, .seconds(1))
    }

    func testSessionRejectsUnparsableAuthorizeURL() async {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"authorizeUrl":"not a url"}}"#.utf8))
        }

        await XCTAssertThrowsErrorAsync(
            try await LLMCenterAuthClient(http: http).createSession(api: self.api, state: "abc")
        ) { error in
            XCTAssertEqual(error as? LLMCenterSignInError, .authorizeURLInvalid)
        }
    }

    func testSessionRejectsStateMismatch() async {
        let http = RoutingHTTPClient { _ in Self.sessionResponse(state: "someone-else") }

        await XCTAssertThrowsErrorAsync(
            try await LLMCenterAuthClient(http: http).createSession(api: self.api, state: "abc")
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
            let session = try await LLMCenterAuthClient(http: http).createSession(api: api, state: "abc")
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

    func testPollPendingWhenNoWebToken() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"status":"pending","webToken":null}}"#.utf8))
        }

        let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

        XCTAssertEqual(result, .pending)
    }

    func testPollSucceedsOnNonEmptyWebTokenRegardlessOfStatus() async throws {
        // The completion-state status literal was never observed against the real server, so a token in
        // hand wins no matter what the status says. Matching on the status instead would risk throwing
        // away a token we were actually handed.
        for status in ["\"success\"", "\"authorized\"", "\"done\"", "\"\"", "null"] {
            let http = RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"code":0,"data":{"status":\(status),"webToken":"tok-new","appCode":"app-1"}}
                """.utf8))
            }

            let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

            XCTAssertEqual(result, .authorized(webToken: "tok-new", appCode: "app-1"), "status \(status)")
        }
    }

    func testPollTreatsUnknownStatusWithoutTokenAsFailure() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"status":"revoked","webToken":null}}"#.utf8))
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

    func testPollEmptyStringTokenIsNotSuccess() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"data":{"status":"pending","webToken":"  "}}"#.utf8))
        }

        let result = try await LLMCenterAuthClient(http: http).poll(api: api, state: "abc")

        XCTAssertEqual(result, .pending)
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
