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
    private static func http(polls: [String], recordingInto hosts: RequestedHosts? = nil) -> RoutingHTTPClient {
        let session = """
        {"code":0,"data":{"state":"deadbeef","authorizeUrl":"https://portal.example.test/cli-auth?state=deadbeef",\
        "expiresIn":300,"pollIntervalMs":1000}}
        """
        let counter = Counter()
        return RoutingHTTPClient { request in
            hosts?.record(request.url.absoluteString)
            if request.url.path.hasSuffix("/session") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(session.utf8))
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

    private static let pending = #"{"code":0,"data":{"status":"pending","webToken":null}}"#
    private static func authorized(appCode: String = "null") -> String {
        #"{"code":0,"data":{"status":"success","webToken":"tok-new","appCode":\#(appCode)}}"#
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
        autoEnabled: Bool = true
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
            isAutoEnabled: { autoEnabled }
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
        XCTAssertEqual(saved["app_code"] as? String, "old-app", "poll returned no appCode, so the CLI's must survive")
        XCTAssertEqual(saved["web_token"] as? String, "tok-new")
    }

    func testConfigWriteAddsAppCodeOnlyWhenPollReturnsOne() async throws {
        let (store, files) = makeStore()
        let service = makeService(store: store, http: Self.http(polls: [Self.authorized(appCode: "\"app-9\"")]))

        await runToCompletion(service)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any])
        XCTAssertEqual(saved["app_code"] as? String, "app-9")
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
            http: Self.http(polls: [#"{"code":0,"data":{"status":"revoked","webToken":null}}"#])
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
        XCTAssertTrue(
            requested.all.allSatisfy { $0.hasPrefix(LLMCenterHost.live) },
            "the built-in live host must be what gets called, got \(requested.all)"
        )
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any]
        )
        XCTAssertEqual(saved["web_token"] as? String, "tok-new")
        XCTAssertEqual(saved["api"] as? String, LLMCenterHost.live, "the host it signed in against is recorded")
    }

    // MARK: - Gating

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

    func testAutoSignInFiresOnlyOncePerSession() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http)

        service.signInAutomatically()
        await drain(service)
        service.dismissResult()
        service.signInAutomatically()
        await Task.yield()

        XCTAssertEqual(service.phase, .idle, "the second attempt must not start a flow")
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/session") }.count, 1)
    }

    func testAutoSignInSkippedWhenSettingOff() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http, autoEnabled: false)

        service.signInAutomatically()
        await Task.yield()

        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAutoSignInSkippedBeforeFirstRefreshPass() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http, hasCompletedFirstRefresh: false)

        service.signInAutomatically()
        await Task.yield()

        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testManualSignInStillWorksAfterAnAutoAttempt() async throws {
        let (store, _) = makeStore()
        let http = Self.http(polls: [Self.authorized()])
        let service = makeService(store: store, http: http)

        service.signInAutomatically()
        await drain(service)
        service.dismissResult()

        XCTAssertTrue(service.signIn(), "the once-per-session cap applies to the automatic path only")
    }

    // MARK: - State nonce

    func testStateIs48HexCharacters() throws {
        let first = try LLMCenterSignInService.makeState()
        let second = try LLMCenterSignInService.makeState()

        XCTAssertEqual(first.count, 48)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(first, second)
    }

    // MARK: - On-disk permissions

    func testWrittenConfigKeeps0600Permissions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llmcenter-signin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json").path
        let store = LLMCenterAuthStore(files: LocalTextFileAccessor(), configPath: path)

        try store.save(webToken: "tok-new", appCode: nil, api: api)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777, 0o600)
    }
}
