import XCTest
@testable import OpenUsage

// MARK: - LLMCenterAuthStoreTests

final class LLMCenterAuthStoreTests: XCTestCase {
    private let configPath = "/tmp/fake/llmctl/config.json"

    func testReadsLoginFromConfigFile() throws {
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: #"{"api":"https://llm-center.modelbest.co","web_token":"tok-123"}"#]),
            configPath: configPath
        )

        let auth = try store.loadAuth()

        XCTAssertEqual(auth?.apiBaseURL, "https://llm-center.modelbest.co")
        XCTAssertEqual(auth?.webToken, "tok-123")
    }

    /// The public `.cn` entry point was shut down (a WAF answers every path), and a saved login keeps
    /// naming the host it was made against — so a login made before the shutdown must be migrated on
    /// read or every metric fails against a dead host.
    func testRetiredHostIsMigratedOnRead() throws {
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: #"{"api":"https://llm-center.modelbest.cn","web_token":"tok-123"}"#]),
            configPath: configPath
        )

        XCTAssertEqual(try store.loadAuth()?.apiBaseURL, "https://llm-center.modelbest.co")
        XCTAssertEqual(try store.loadAPIBaseURL(), "https://llm-center.modelbest.co")
    }

    func testRetiredAliHostIsMigratedOnRead() throws {
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: #"{"api":"https://llm-center.ali.modelbest.co","web_token":"tok-123"}"#]),
            configPath: configPath
        )

        XCTAssertEqual(try store.loadAuth()?.apiBaseURL, "https://llm-center.modelbest.co")
    }

    /// Only hosts confirmed dead are rewritten. A deployment we've never heard of is passed through —
    /// silently redirecting it would be worse than failing honestly.
    func testUnknownHostIsLeftAlone() throws {
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: #"{"api":"https://llm-center.internal.example","web_token":"t"}"#]),
            configPath: configPath
        )

        XCTAssertEqual(try store.loadAuth()?.apiBaseURL, "https://llm-center.internal.example")
    }

    /// Migrating only in memory would leave a dead host on disk for anything else reading the file, so
    /// a sign-in write repairs the recorded value too.
    func testSaveRepairsARetiredHostOnDisk() throws {
        let files = FakeFiles([configPath: #"{"api":"https://llm-center.modelbest.cn","web_token":"old"}"#])
        let store = LLMCenterAuthStore(files: files, configPath: configPath)

        try store.save(webToken: "tok-new", appCode: nil, api: "https://llm-center.modelbest.co")

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any])
        XCTAssertEqual(saved["api"] as? String, "https://llm-center.modelbest.co")
        XCTAssertEqual(saved["web_token"] as? String, "tok-new")
    }

    func testMissingFileIsNotLoggedIn() throws {
        let store = LLMCenterAuthStore(files: FakeFiles(), configPath: configPath)

        XCTAssertNil(try store.loadAuth())
    }

    func testMissingFieldsIsNotLoggedIn() throws {
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: #"{"api":"https://example.com"}"#]),
            configPath: configPath
        )

        XCTAssertNil(try store.loadAuth())
    }

    /// Sign-in needs the server host even when the token is gone — that's the whole point of the
    /// recovery path — so this reads through where `loadAuth()` returns nil.
    func testLoadAPIBaseURLReturnsAPIEvenWithoutWebToken() throws {
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: #"{"api":"https://example.com","web_token":""}"#]),
            configPath: configPath
        )

        XCTAssertNil(try store.loadAuth())
        XCTAssertEqual(try store.loadAPIBaseURL(), "https://example.com")
    }

    func testLoadAPIBaseURLFallsBackToTheLiveHostWhenNoFileExists() throws {
        // First run with nothing on disk: sign-in still has a server to authorize against, which is what
        // makes the first login possible without any external setup.
        let store = LLMCenterAuthStore(files: FakeFiles(), configPath: configPath)

        XCTAssertEqual(try store.loadAPIBaseURL(), LLMCenterHost.live)
    }

    func testSaveRewritesAnUnparsableConfigRatherThanTrappingTheUser() throws {
        let files = FakeFiles([configPath: "not-json"])
        let store = LLMCenterAuthStore(files: files, configPath: configPath)

        try store.save(webToken: "tok-new", appCode: nil, api: "https://example.com")

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(files.files[configPath]).utf8)) as? [String: Any])
        XCTAssertEqual(saved["web_token"] as? String, "tok-new")
        XCTAssertEqual(saved["api"] as? String, "https://example.com")
    }

    func testInvalidJSONThrows() {
        let store = LLMCenterAuthStore(
            files: FakeFiles([configPath: "not-json"]),
            configPath: configPath
        )

        XCTAssertThrowsError(try store.loadAuth()) { error in
            XCTAssertEqual(error as? LLMCenterAuthError, .credentialsUnreadable(detail: "config.json is not valid JSON"))
        }
    }

    func testDefaultConfigPathTargetsTheSharedConfigFile() {
        XCTAssertTrue(LLMCenterAuthStore.defaultConfigPath().hasSuffix("llmctl/config.json"))
    }
}

// MARK: - LLMCenterUsageMapperTests

final class LLMCenterUsageMapperTests: XCTestCase {
    private var now: Date!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = .current
        now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12))!
    }

    func testQuotaLineMapsOfficialSpend() {
        guard case .progress(let label, let used, let limit, let format, _, _, _, _) =
            LLMCenterUsageMapper.quotaLine(spent: 150.1021, quota: 7000)
        else {
            return XCTFail("expected a quota progress line")
        }
        XCTAssertEqual(label, "This Month")
        XCTAssertEqual(used, 150.1021, accuracy: 0.0001)
        XCTAssertEqual(limit, 7000)
        XCTAssertEqual(format, .yuan)
    }

    func testQuotaLineNilWithoutPositiveQuota() {
        XCTAssertNil(LLMCenterUsageMapper.quotaLine(spent: 5, quota: 0))
    }

    func testSoftDailyQuotaSpreadsMonthlyQuotaOverMonthDays() {
        // August 2026 has 31 days → 7000 / 31 ≈ 225.81.
        let soft = LLMCenterUsageMapper.softDailyQuota(monthlyQuota: 7000, now: now, calendar: calendar)
        XCTAssertEqual(soft, 7000.0 / 31.0, accuracy: 0.0001)
    }

    func testTodayLineIsSoftQuotaMeter() {
        guard case .progress(let label, let used, let limit, let format, _, _, _, let breakdown) =
            LLMCenterUsageMapper.todayLine(cost: 60.61, softLimit: 225.81)
        else {
            return XCTFail("expected a Today progress line")
        }
        XCTAssertEqual(label, "Today")
        XCTAssertEqual(used, 60.61, accuracy: 0.0001)
        XCTAssertEqual(limit, 225.81, accuracy: 0.0001)
        XCTAssertEqual(format, .yuan)
        XCTAssertNil(breakdown)
    }

    func testYesterdayLineIsOfficialSpendRow() {
        guard case .values(let label, let values, _, _, _, _) =
            LLMCenterUsageMapper.yesterdayLine(cost: 34.19, tokens: 15_273_231)
        else {
            return XCTFail("expected a Yesterday values line")
        }
        XCTAssertEqual(label, "Yesterday")
        XCTAssertEqual(values.first { $0.kind == .yuan }?.number ?? 0, 34.19, accuracy: 0.0001)
        XCTAssertEqual(values.first { $0.kind == .count }?.number ?? 0, 15_273_231)
    }

    func testBreakdownFiltersByPeriod() {
        let rows: [[String: Any]] = [
            ["date": "2026-08-05", "modelName": "GPT-5.6-Sol", "totalTokens": 748_305, "cost": 1.698695],
            ["date": "2026-08-05", "modelName": "GPT-5.6-Luna", "totalTokens": 586_600, "cost": 0.070673],
            ["date": "2026-08-04", "modelName": "GPT-5.6-Sol", "totalTokens": 1000, "cost": 0.05]
        ]

        let today = LLMCenterUsageMapper.breakdown(
            rows: rows, matching: { $0 == "2026-08-05" }, totalCost: 1.77, totalTokens: 1_334_905
        )
        XCTAssertEqual(today?.models.count, 2)
        XCTAssertEqual(today?.costKind, .yuan)
        XCTAssertEqual(today?.models.first?.model, "GPT-5.6-Sol")

        let month = LLMCenterUsageMapper.breakdown(
            rows: rows, matching: { $0.hasPrefix("2026-08") }, totalCost: 1.82, totalTokens: 1_335_905
        )
        XCTAssertEqual(month?.models.count, 2)
        XCTAssertEqual(month?.models.first { $0.model == "GPT-5.6-Sol" }?.totalTokens, 749_305)
    }

    func testBreakdownNilWithoutMatchingRows() {
        XCTAssertNil(LLMCenterUsageMapper.breakdown(
            rows: [["date": "2026-08-04", "modelName": "M", "totalTokens": 1, "cost": 0.1]],
            matching: { $0 == "2026-08-05" },
            totalCost: 0, totalTokens: 0
        ))
    }
}

// MARK: - LLMCenterProviderTests

@MainActor
final class LLMCenterProviderTests: XCTestCase {
    private let configPath = "/tmp/fake/llmctl/config.json"
    private let myUserId = "24f870ddc1104c66a5d4b512f6031d15"

    private func makeProvider(
        http: RoutingHTTPClient,
        config: String? = #"{"api":"https://llm-center.modelbest.co","web_token":"tok-123"}"#
    ) -> LLMCenterProvider {
        let now = pinnedNow
        return LLMCenterProvider(
            authStore: LLMCenterAuthStore(
                files: FakeFiles(config.map { [configPath: $0] } ?? [:]),
                configPath: configPath
            ),
            usageClient: LLMCenterUsageClient(http: http),
            now: { now }
        )
    }

    private func body(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// The clock every routed-client test runs on: midday on 2026-08-05, local time. Pinned (rather than
    /// `Date()`) because the fixtures below carry literal `yyyy-MM-dd` rows and the assertions divide the
    /// monthly quota by the month's day count — both of which would drift with the real calendar.
    private var pinnedNow: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 5
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    /// Routes by URL path. Statistics requests are told apart by the `startDate` in the body so today
    /// and yesterday return their own official figures. Every body is pre-built as `Data` so the
    /// `@Sendable` handler captures only Sendable values.
    private func routedClient() -> RoutingHTTPClient {
        let userId = myUserId
        let deptBody = body(["code": 0, "data": ["userId": userId, "deptId": 16, "deptName": "文本组"]])
        let membersBody = body(["code": 0, "data": [
            ["userId": "someone-else", "memberQuota": 7000.0, "effectiveQuota": 7000.0, "spentAmount": 900.0],
            ["userId": userId, "memberQuota": 7000.0, "effectiveQuota": 7000.0, "spentAmount": 150.1021, "remainingQuota": 6849.8979]
        ]])
        let statsToday = body(["code": 0, "data": ["totalCost": 60.61, "totalTokens": 78_837_745, "totalCalls": 537]])
        let statsYesterday = body(["code": 0, "data": ["totalCost": 34.19, "totalTokens": 15_273_231, "totalCalls": 209]])
        let detailsBody = body(["code": 0, "data": [
            "aggregationType": "DAY", "totalCount": 3, "pageSize": 500, "currentPage": 1,
            "detailList": [
                ["date": "2026-08-05", "modelName": "GPT-5.6-Sol", "totalTokens": 748_305, "cost": 1.698695],
                ["date": "2026-08-05", "modelName": "GPT-5.6-Luna", "totalTokens": 586_600, "cost": 0.070673],
                ["date": "2026-08-04", "modelName": "GPT-5.6-Sol", "totalTokens": 1000, "cost": 0.05]
            ]
        ]])
        let yesterdayDateString = calendarDay(-1)

        return RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/llm/api/department/my") {
                return HTTPResponse(statusCode: 200, headers: [:], body: deptBody)
            }
            if path.hasSuffix("/llm/api/department/16/members") {
                return HTTPResponse(statusCode: 200, headers: [:], body: membersBody)
            }
            if path.hasSuffix("/llm/api/usage/user-model-details") {
                return HTTPResponse(statusCode: 200, headers: [:], body: detailsBody)
            }
            if path.hasSuffix("/llm/api/usage/statistics") {
                let object = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
                let startDate = object?["startDate"] as? String ?? ""
                let body = startDate.hasSuffix(yesterdayDateString) ? statsYesterday : statsToday
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            }
            XCTFail("unexpected request path: \(path)")
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
    }

    private func calendarDay(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: pinnedNow) ?? pinnedNow
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func testRefreshShowsQuotaMeterSoftDailyBarAndYesterday() async {
        let snapshot = await makeProvider(http: routedClient()).refresh()

        XCTAssertEqual(snapshot.providerID, "llmcenter")
        XCTAssertNil(snapshot.errorCategory)

        guard case .progress(_, let monthUsed, let monthLimit, _, _, _, _, let monthBreakdown) =
            snapshot.lines.first(where: { $0.label == "This Month" })
        else {
            return XCTFail("expected the official quota meter")
        }
        XCTAssertEqual(monthUsed, 150.1021, accuracy: 0.0001)
        XCTAssertEqual(monthLimit, 7000)
        XCTAssertEqual(monthBreakdown?.models.count, 2)

        guard case .progress(_, let todayUsed, let todayLimit, _, _, _, _, let todayBreakdown) =
            snapshot.lines.first(where: { $0.label == "Today" })
        else {
            return XCTFail("expected the Today soft-quota meter")
        }
        XCTAssertEqual(todayUsed, 60.61, accuracy: 0.0001)
        XCTAssertEqual(todayLimit, 7000.0 / 31.0, accuracy: 0.0001)
        XCTAssertEqual(todayBreakdown?.models.count, 2)

        guard case .values(let yesterdayLabel, let values, _, _, _, _) =
            snapshot.lines.first(where: { $0.label == "Yesterday" })
        else {
            return XCTFail("expected the Yesterday spend row")
        }
        XCTAssertEqual(yesterdayLabel, "Yesterday")
        XCTAssertEqual(values.first { $0.kind == .yuan }?.number ?? 0, 34.19, accuracy: 0.0001)
    }

    func testRefreshReportsExpiredToken() async {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    func testRefreshWithoutLoginIsNotLoggedIn() async {
        let provider = makeProvider(http: RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }, config: nil)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    func testHasLocalCredentialsMirrorsLoginFile() async {
        let loggedIn = makeProvider(http: routedClient())
        let hasCreds = await loggedIn.hasLocalCredentials()
        XCTAssertTrue(hasCreds)

        let loggedOut = makeProvider(http: routedClient(), config: nil)
        let hasCredsLoggedOut = await loggedOut.hasLocalCredentials()
        XCTAssertFalse(hasCredsLoggedOut)
    }

    func testWidgetDescriptorIDs() {
        let provider = makeProvider(http: routedClient())

        XCTAssertEqual(provider.widgetDescriptors.map(\.id),
                       ["llmcenter.today", "llmcenter.month", "llmcenter.yesterday", "llmcenter.trend"])
    }

    /// The Usage Trend row spans the month so far, one ¥ bar per calendar day — zero-filled on idle days
    /// so the sparkline stays calendar-true.
    func testRefreshBuildsMonthToDateSpendTrend() async {
        let snapshot = await makeProvider(http: routedClient()).refresh()

        guard case .chart(let label, let points, let note) =
            snapshot.lines.first(where: { $0.label == "Usage Trend" })
        else {
            return XCTFail("expected the Usage Trend chart line")
        }
        XCTAssertEqual(label, "Usage Trend")
        XCTAssertNotNil(note)
        // Aug 1 through Aug 5 (the pinned clock), inclusive.
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.first?.value ?? -1, 0, accuracy: 0.0001)          // Aug 1: idle, zero-filled
        XCTAssertEqual(points[3].value, 0.05, accuracy: 0.0001)           // Aug 4: one detail row
        XCTAssertEqual(points[4].value, 1.769368, accuracy: 0.0001)       // Aug 5: two detail rows summed
    }

    func testYuanFormatting() {
        XCTAssertEqual(MetricFormatter.number(56.40, kind: .yuan, style: .row), "¥56.40")
        XCTAssertEqual(MetricFormatter.number(56.40, kind: .yuan, style: .tray), "¥56")
        XCTAssertEqual(MetricFormatter.number(1234, kind: .yuan, style: .row), "¥1.2K")
        XCTAssertEqual(MetricFormatter.number(2059.07, kind: .yuan, style: .full), "¥2,059.07")
    }
}
