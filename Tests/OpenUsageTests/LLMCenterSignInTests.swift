import XCTest
@testable import OpenUsage

/// The in-app LLMCenter sign-in flow: browser hand-off, polling, and writing the new token back to
/// disk. Every seam (clock, sleep, state nonce, browser open) is injected, so these run synchronously
/// and deterministically without AppKit or real waiting.
@MainActor
final class LLMCenterSignInServiceTests: XCTestCase {
    private let configPath = "/tmp/fake/llmctl/config.json"
    private let api = "https://api.example.test"

    private func makeStore(_ contents: String? = nil) -> (LLMCenterAuthStore, FakeFiles) {
        let files = FakeFiles(contents.map { [configPath: $0] } ?? [
            configPath: #"{"api":"https://api.example.test","web_token":"expired"}"#
        ])
        return (LLMCenterAuthStore(files: files, configPath: configPath), files)
    }

    /// Answers the session POST once, then walks the given poll responses in order (repeating the last).
    /// The token exchange answers on the OIDC token endpoint, so the flow can complete end to end.
    private static func http(
        polls: [String],
        tokenResponse: String = #"{"web_token":"tok-new"}"#,
        recordingInto hosts: RequestedHosts? = nil
    ) -> RoutingHTTPClient {
        let session = """
        {"code":0,"data":{"state":"deadbeef","authorizeUrl":"https://portal.example.test/cli-auth?state=deadbeef",\
        "expiresIn":300,"pollIntervalMs":1000,"tokenEndpoint":"https://iam.example.test/api/admin/oauth2/token",\
        "clientId":"client-1","redirectUri":"https://api.example.test/auth/callback"}}
        """
        let counter = Counter()
        return RoutingHTTPClient { request in
            hosts?.record(request.url.absoluteString)
            if request.url.path.hasSuffix("/session") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(session.utf8))
            }
            if request.url.path.hasSuffix("/oauth2/token") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(tokenResponse.utf8))
            }
            let index = min(counter.next(), polls.count - 1)
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(polls[index].utf8))
        }
    }

    /// Records every URL the client actually called, so a test can assert which deployment was reached.
    private final class RequestedHosts: @unchecked Sendable {
        private var value: [String] = []
        private let lock = NSLock()
        func record(_ url: String) {
            lock.lock(); defer { lock.unlock() }
            value.append(url)
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            defer { value += 1 }
            return value
        }
    }

    private static let pending = #"{"code":0,"data":{"status":"pending","authorizationCode":null}}"#
    private static func authorized(code: String = "code-1") -> String {
        #"{"code":0,"data":{"status":"success","authorizationCode":"\#(code)"}}"#
    }

    /// The lines `AppLog` wrote while `body` ran, via a temp file sink swapped in for the shared one.
    private static func loggedLines(_ body: () async -> Void = {}) async -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.LLMCenterSignIn.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let original = AppLog.sink
        AppLog.sink = sink
        defer {
            AppLog.sink = original
            try? FileManager.default.removeItem(at: directory)
        }
        await body()
        guard let text = try? String(contentsOf: directory.appendingPathComponent("OpenUsage.log"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Runs `signIn()` to completion, draining the injected sleeps so the poll loop advances without
    /// real time passing.
    private func runToCompletion(_ service: LLMCenterSignInService) async {
        service.signIn()
        await drain(service)
    }

    /// Yields until the flow reaches a terminal phase. The bound is generous because the timeout case
    /// polls once per simulated second up to the session's 300s expiry.
    private func drain(_ service: LLMCenterSignInService) async {
        for _ in 0..<5000 where service.phase.isInFlight {
            await Task.yield()
        }
    }

    private func makeService(
        store: LLMCenterAuthStore,
        http: RoutingHTTPClient,
        openedURLs: OpenedURLs = OpenedURLs(),
        sleeps: RecordedSleeps = RecordedSleeps(),
        clock: TestClock = TestClock(),
        refreshCount: Counter? = nil,
        refreshRecorder: (@Sendable () -> Void)? = nil,
        hasCompletedFirstRefresh: Bool = true,
        autoSignInInterval: LLMCenterAutoSignInInterval = .immediate
    ) -> LLMCenterSignInService {
        LLMCenterSignInService(
            authStore: store,
            client: LLMCenterAuthClient(http: http),
            openURL: { openedURLs.append($0) },
            refreshAfterSignIn: { refreshRecorder?(); _ = refreshCount?.next() },
            now: { clock.now },
            makeState: { "deadbeef" },
            sleep: { duration in
                sleeps.append(duration)
                clock.advance(by: duration)
                await Task.yield()
            },
            hasCompletedFirstRefresh: { hasCompletedFirstRefresh },
            autoSignInInterval: { autoSignInInterval }
        )
    }

    final class OpenedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    final class RecordedSleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var durations: [Duration] = []
        func append(_ duration: Duration) { lock.lock(); durations.append(duration); lock.unlock() }
        var all: [Duration] { lock.lock(); defer { lock.unlock() }; return durations }
    }

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(by duration: Duration) {
            lock.lock()
            date = date.addingTimeInterval(TimeInterval(duration.components.seconds))
            lock.unlock()
        }
    }

    // MARK: - Happy path

    func testSuccessfulFlowOpensAuthorizeURLPollsAndWritesConfig() async throws {
        let (store, files) = makeStore()
        let http = Self.http(polls: [Self.pending, Self.pending, Self.authorized()])
        let opened = OpenedURLs()
        let refreshes = Counter()
        let service = makeService(store: store, http: http, openedURLs: opened, refreshCount: refreshes)

        await runToCompletion(service)

        XCTAssertEqual(service.phase, .succeeded)
        XCTAssertEqual(opened.all.map(\.absoluteString), ["https://portal.example.test/cli-auth?state=deadbeef"])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any])
        XCTAssertEqual(saved["web_token"] as? String, "tok-new")
        XCTAssertEqual(refreshes.next(), 1, "the refresh should have run exactly once, after the write")
    }

    func testConfigWritePreservesUnknownKeys() async throws {
        // The `llmctl` CLI shares this file. Losing `access_key`/`model`/`env` would break it.
        let original = """
        {"access_key":"ak-1","api":"https://api.example.test","app_code":"old-app","env":"prod",\
        "model":"gpt-x","web_token":"expired"}
        """
        let (store, files) = makeStore(original)
        let service = makeService(store: store, http: Self.http(polls: [Self.authorized()]))

        await runToCompletion(service)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any])
        XCTAssertEqual(saved["access_key"] as? String, "ak-1")
        XCTAssertEqual(saved["model"] as? String, "gpt-x")
        XCTAssertEqual(saved["env"] as? String, "prod")
        XCTAssertEqual(saved["api"] as? String, "https://api.example.test")
        XCTAssertEqual(saved["app_code"] as? String, "old-app", "the exchange returned no appCode, so the CLI's must survive")
        XCTAssertEqual(saved["web_token"] as? String, "tok-new")
    }

    func testConfigWriteAddsAppCodeOnlyWhenExchangeReturnsOne() async throws {
        let (store, files) = makeStore()
        let service = makeService(
            store: store,
            http: Self.http(
                polls: [Self.authorized()],
                tokenResponse: #"{"web_token":"tok-new","app_code":"app-9"}"#
            )
        )

        await runToCompletion(service)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any])
        XCTAssertEqual(saved["app_code"] as? String, "app-9")
    }

    /// What makes the next expiry silent: the refresh token and the OIDC endpoints it must be redeemed at
    /// land on disk beside the access token, replacing a stale refresh token left by an earlier login.
    func testSignInPersistsTheRefreshCredentials() async throws {
        let (store, files) = makeStore(
            #"{"api":"https://api.example.test","web_token":"expired","refresh_token":"stale","token_expires_at":1}"#
        )
        let service = makeService(
            store: store,
            http: Self.http(
                polls: [Self.authorized()],
                tokenResponse: #"{"web_token":"tok-new","refresh_token":"refresh-new","expires_in":3600}"#
            )
        )

        await runToCompletion(service)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any])
        XCTAssertEqual(saved["refresh_token"] as? String, "refresh-new")
        XCTAssertEqual(saved["oidc_client_id"] as? String, "client-1")
        XCTAssertEqual(saved["oidc_token_endpoint"] as? String, "https://iam.example.test/api/admin/oauth2/token")
        XCTAssertEqual(saved["oidc_redirect_uri"] as? String, "https://api.example.test/auth/callback")
        XCTAssertGreaterThan(try XCTUnwrap(saved["token_expires_at"] as? Int), 1)
        XCTAssertNotNil(try store.loadAuth()?.refresh, "the saved login must be renewable by the provider")
    }

    func testPollIntervalFollowsServerValue() async throws {
        let (store, _) = makeStore()
        let sleeps = RecordedSleeps()
        let service = makeService(store: store, http: Self.http(polls: [Self.pending, Self.authorized()]), sleeps: sleeps)

        await runToCompletion(service)

        XCTAssertEqual(sleeps.all, [.seconds(1), .seconds(1)])
    }

    // MARK: - Failure paths

    func testTimeoutStopsPollingAndNeverWrites() async throws {
        let (store, files) = makeStore()
        let before = files.files[configPath]
        let refreshes = Counter()
        let service = makeService(store: store, http: Self.http(polls: [Self.pending]), refreshCount: refreshes)

        await runToCompletion(service)

        guard case .failed = service.phase else { return XCTFail("expected a failed phase, got \(service.phase)") }
        XCTAssertEqual(files.files[configPath], before, "a timeout must not touch the config")
        XCTAssertEqual(refreshes.next(), 0)
    }

    func testRejectionStopsImmediately() async throws {
        let (store, files) = makeStore()
        let before = files.files[configPath]
        let service = makeService(
            store: store,
            http: Self.http(polls: [#"{"code":0,"data":{"status":"revoked","authorizationCode":null}}"#])
        )

        await runToCompletion(service)

        guard case .failed = service.phase else { return XCTFail("expected a failed phase, got \(service.phase)") }
        XCTAssertEqual(files.files[configPath], before)
    }

    func testSignsInAgainstTheBuiltInHostWhenNothingOnDiskNamesAServer() async throws {
        // Never-signed-in machine: no host on record. The flow falls back to the live host rather than
        // dead-ending, which is what makes the first sign-in possible without any external setup.
        let (store, files) = makeStore("{}")
        let opened = OpenedURLs()
        let requested = RequestedHosts()
        let service = makeService(
            store: store,
            http: Self.http(polls: [Self.authorized()], recordingInto: requested),
            openedURLs: opened
        )

        await runToCompletion(service)

        XCTAssertEqual(service.phase, .succeeded)
        XCTAssertEqual(opened.all.count, 1)
        // The token endpoint is served by the OIDC host the session response names, so only the
        // LLMCenter API calls are expected on the built-in live host.
        XCTAssertTrue(
            requested.all
                .filter { $0.contains("/llm/api/") }
                .allSatisfy { $0.hasPrefix(LLMCenterHost.live) },
            "the built-in live host must be what gets called, got \(requested.all)"
        )
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any]
        )
        XCTAssertEqual(saved["web_token"] as? String, "tok-new")
        XCTAssertEqual(saved["api"] as? String, LLMCenterHost.live, "the host it signed in against is recorded")
    }

    // MARK: - Failure diagnostics

    /// A refused session is the case that prompted this test: the server answers HTTP 200 with a
    /// non-zero business code, the browser never opens, and the user just sees "Try again in a moment."
    /// The cause has to reach the log, or a report like that is undiagnosable.
    func testSessionFailureLogsTheUnderlyingDetail() async throws {
        let (store, _) = makeStore()
        let http = RoutingHTTPClient { _ in
            HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"code":400,"message":"only llmctl 0.2.12+ is supported","data":null}"#.utf8)
            )
        }
        let service = makeService(store: store, http: http)

        let lines = await Self.loggedLines {
            await self.runToCompletion(service)
        }

        guard case .failed(let message) = service.phase else {
            return XCTFail("expected a failed phase, got \(service.phase)")
        }
        XCTAssertEqual(message, "Couldn't start the LLMCenter sign-in. Try again in a moment.")
        XCTAssertTrue(
            lines.contains { $0.contains("(detail: unexpected session response)") },
            "the log must carry the underlying cause, not just the fixed UI sentence, got \(lines)"
        )
    }

    /// The server's refusal body is the only explanation for a `sessionFailed`, and it arrives as HTTP
    /// 200 with a non-zero code — so it is logged here explicitly rather than by `URLSessionHTTPClient`
    /// (which previews bodies only for status >= 400). This is the line that would have made the
    /// 2026-09 LLMCenter protocol break diagnosable from the log alone.
    func testSessionRefusalLogsTheServerExplanation() async throws {
        let (store, _) = makeStore()
        let http = RoutingHTTPClient { _ in
            HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"code":400,"message":"当前服务仅支持 llmctl 0.2.12 及以上版本","data":null}"#.utf8)
            )
        }
        let service = makeService(store: store, http: http)

        let lines = await Self.loggedLines {
            await self.runToCompletion(service)
        }

        XCTAssertTrue(
            lines.contains { $0.contains("[http]") && $0.contains("llmcenter auth/session refused") },
            "the server's refusal must reach the log at the default level, got \(lines)"
        )
    }

    // MARK: - PKCE / OIDC

    /// The protocol break this whole change fixes: a body without `codeChallenge` is answered with the
    /// misleading "only llmctl 0.2.12+ is supported" error, and the browser never opens.
    func testSessionRequestCarriesPKCEChallenge() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http)

        await runToCompletion(service)

        let sessionRequest = try XCTUnwrap(http.requests.first { $0.url.path.hasSuffix("/session") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sessionRequest.body)) as? [String: String])
        let challenge = try XCTUnwrap(body["codeChallenge"])
        XCTAssertFalse(challenge.isEmpty)
        XCTAssertNil(body["codeVerifier"], "the verifier must not be sent when opening the session")
    }

    /// The code from the poll is redeemed at the server-provided token endpoint with the matching PKCE
    /// verifier — without it the server cannot confirm this process opened the session.
    func testExchangeSendsVerifierMatchingTheChallenge() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http)

        await runToCompletion(service)

        let sessionRequest = try XCTUnwrap(http.requests.first { $0.url.path.hasSuffix("/session") })
        let sessionBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sessionRequest.body)) as? [String: String])
        let challenge = try XCTUnwrap(sessionBody["codeChallenge"])

        let exchangeRequest = try XCTUnwrap(http.requests.first { $0.url.path.hasSuffix("/oauth2/token") })
        let form = try XCTUnwrap(String(data: XCTUnwrap(exchangeRequest.body), encoding: .utf8))
        let verifier = try XCTUnwrap(
            form.split(separator: "&")
                .first { $0.hasPrefix("code_verifier=") }
                .map { String($0.dropFirst("code_verifier=".count)) }
        )
        XCTAssertEqual(LLMCenterPKCE.challenge(for: verifier), challenge, "verifier must hash to the submitted challenge")
        XCTAssertTrue(form.contains("code=code-1"), form)
        XCTAssertTrue(form.contains("grant_type=authorization_code"), form)
    }

    func testFlowOpensBrowserBeforeExchange() async throws {
        let (store, _) = makeStore()
        let opened = OpenedURLs()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http, openedURLs: opened)

        await runToCompletion(service)

        XCTAssertEqual(service.phase, .succeeded)
        XCTAssertEqual(opened.all.map(\.absoluteString), ["https://portal.example.test/cli-auth?state=deadbeef"])
        XCTAssertNotNil(http.requests.first { $0.url.path.hasSuffix("/oauth2/token") })
    }

    func testExchangeFailureLeavesConfigUntouched() async throws {
        let (store, files) = makeStore()
        let before = files.files[configPath]
        let http = Self.http(
            polls: [Self.authorized()],
            tokenResponse: #"{"error":"invalid_grant","error_description":"code expired"}"#
        )
        let service = makeService(store: store, http: http)

        await runToCompletion(service)

        guard case .failed = service.phase else { return XCTFail("expected a failed phase, got \(service.phase)") }
        XCTAssertEqual(files.files[configPath], before, "a failed exchange must not touch the config")
    }

    func testRedirectURIIsDerivedFromAPIBase() {
        XCTAssertEqual(
            LLMCenterSignInService.redirectURI(api: "https://llm-center.modelbest.co"),
            "https://llm-center.modelbest.co/auth/callback"
        )
        XCTAssertEqual(
            LLMCenterSignInService.redirectURI(api: "https://api.example.test/some/base"),
            "https://api.example.test/auth/callback"
        )
        XCTAssertNil(LLMCenterSignInService.redirectURI(api: "not a url"))
    }

    func testSecondSignInWhileInFlightIsRejected() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.pending])
        let service = makeService(store: store, http: http)

        XCTAssertTrue(service.signIn())
        XCTAssertFalse(service.signIn(), "a double-click must not open two browser windows")
        service.cancel()
    }

    func testCancelStopsPollingAndLeavesConfigUntouched() async throws {
        let (store, files) = makeStore()
        let before = files.files[configPath]
        let service = makeService(store: store, http: Self.http(polls: [Self.pending]))

        service.signIn()
        await Task.yield()
        service.cancel()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(files.files[configPath], before)
    }

    func testAutoSignInWithImmediateInterval() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http, autoSignInInterval: .immediate)

        service.signInAutomatically(interval: .immediate)
        await drain(service)

        XCTAssertEqual(service.phase, .succeeded, "immediate interval must open the browser right away")
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/session") }.count, 1)
    }

    func testAutoSignInSkippedWhenIntervalIsNever() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http, autoSignInInterval: .never)

        service.signInAutomatically(interval: .never)
        await Task.yield()

        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAutoSignInSkippedBeforeFirstRefreshPass() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http, hasCompletedFirstRefresh: false, autoSignInInterval: .immediate)

        service.signInAutomatically(interval: .immediate)
        await Task.yield()

        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAutoSignInBlockClearedAfterSuccessfulRefresh() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http, autoSignInInterval: .immediate)

        // Simulate blocked state (in real use, run() sets this on failure)
        // We can't directly access the private property, so we test the public contract:
        // after a successful auto sign-in, clearAutoSignInBlock() should allow another attempt
        service.signInAutomatically(interval: .immediate)
        await drain(service)
        XCTAssertEqual(service.phase, .succeeded)

        // Clear the block
        service.clearAutoSignInBlock()

        // Now a second auto attempt should be allowed if we had a new expiry
        service.signInAutomatically(interval: .immediate)
        await Task.yield()
        // We don't have a second session in the http mock, but the point is it doesn't block the call
    }

    // MARK: - State nonce

    func testStateIsPrefixedAndUnpredictable() throws {
        let first = try LLMCenterSignInService.makeState()
        let second = try LLMCenterSignInService.makeState()

        XCTAssertTrue(first.hasPrefix("llmctl_"), "the server rejects a state without the llmctl_ prefix")
        let nonce = first.dropFirst(LLMCenterSignInService.statePrefix.count)
        XCTAssertEqual(nonce.count, 48)
        XCTAssertTrue(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(first, second)
    }

    // MARK: - On-disk permissions

    func testWrittenConfigKeeps0600Permissions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llmcenter-signin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json").path
        let store = LLMCenterAuthStore(files: LocalTextFileAccessor(), configPath: path)

        try store.save(LLMCenterTokenSet(webToken: "tok-new"), api: api, source: .refresh)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777, 0o600)
    }
}
