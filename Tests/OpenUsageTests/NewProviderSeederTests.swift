import XCTest
@testable import OpenUsage

/// Covers the new-provider detection pass that runs on every launch: only providers the install has
/// never seen are credential-probed, a probe hit turns the provider on, a miss leaves it off forever
/// (one shot), and providers the user already decided about are never touched.
@MainActor
final class NewProviderSeederTests: XCTestCase {
    func testNewProviderWithCredentialsIsEnabled() async {
        let enablement = seededStore("detect", enabled: ["claude"], known: ["claude", "codex"])
        let providers = [
            probe("claude", hasCredentials: true),
            probe("codex", hasCredentials: true),
            probe("windsurf", hasCredentials: true)
        ]

        let task = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "windsurf"])
        XCTAssertEqual(enablement.knownIDs, ["claude", "codex", "windsurf"])
    }

    func testNewProviderWithoutCredentialsStaysOffAndIsNeverReprobed() async {
        let enablement = seededStore("miss", enabled: ["claude"], known: ["claude"])
        let newcomer = probe("windsurf", hasCredentials: false)

        let firstRun = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), newcomer], enablement: enablement
        )
        await firstRun?.value

        XCTAssertFalse(enablement.isEnabled("windsurf"))
        XCTAssertEqual(newcomer.probeCount, 1)

        // Next launch: windsurf is known now — no task, no second probe. Enabling it is the user's call.
        let secondRun = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), newcomer], enablement: enablement
        )
        XCTAssertNil(secondRun)
        XCTAssertEqual(newcomer.probeCount, 1)
    }

    func testKnownButDisabledProviderIsNeverProbedOrReenabled() async {
        // The user turned grok off at some point; it must never come back on its own — even though a
        // credential probe would hit.
        let enablement = seededStore("user-off", enabled: ["claude"], known: ["claude", "grok"])
        let grok = probe("grok", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), grok], enablement: enablement
        )

        XCTAssertNil(task, "nothing new to detect")
        XCTAssertFalse(enablement.isEnabled("grok"))
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testLegacyModeStoreIsUntouched() {
        // Legacy disabled-list installs get new providers on by default already; the seeder must not
        // switch their mode or write anything.
        let enablement = ProviderEnablementStore(defaults: makeDefaults("legacy"))

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("windsurf", hasCredentials: true)], enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs)
        XCTAssertTrue(enablement.knownIDs.isEmpty)
    }

    func testEmptyKnownSetIsBaselinedWithoutProbing() {
        // An enabled-list store with no known set (an unbundled `swift run` seeded before this
        // shipped): "new" can't be told apart from "user turned it off", so baseline and do nothing.
        let enablement = seededStore("baseline", enabled: ["claude"], known: [])
        let grok = probe("grok", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), grok], enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertEqual(enablement.knownIDs, ["claude", "grok"])
        XCTAssertFalse(enablement.isEnabled("grok"))
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testUserToggleDuringDetectionWins() async {
        let enablement = seededStore("toggle-wins", enabled: ["claude"], known: ["claude"])
        var enableCallbacks: [String] = []
        enablement.onProviderEnabled = { enableCallbacks.append($0) }
        let providers = [probe("claude", hasCredentials: true), probe("windsurf", hasCredentials: true)]

        let task = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
        // The user turns the newcomer on themselves while the probe is still running: the seeder must
        // leave their toggle alone instead of re-setting it.
        enablement.setEnabled(true, for: "windsurf")
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "windsurf"])
        XCTAssertEqual(enableCallbacks, ["windsurf"], "the seeder must not fire a second enable")
    }

    // MARK: - Always-seeded providers

    /// The bug this fixes: a user who arrives at LLMCenter through an update (not a fresh install) gets
    /// the card. Its credentials are written by the card's own Sign In button, so a probe can never hit
    /// on a machine that has not signed in — it must be enabled without one.
    func testAlwaysSeededNewProviderIsEnabledWithoutACredentialProbe() async {
        let enablement = seededStore("always-seeded", enabled: ["claude", "copilot"],
                                     known: ["claude", "copilot", "codex", "cursor"])
        let llmCenter = probe("llmcenter", hasCredentials: false)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), llmCenter], enablement: enablement
        )
        await task?.value

        XCTAssertTrue(enablement.isEnabled("llmcenter"), "an update must not hide the card")
        XCTAssertEqual(llmCenter.probeCount, 0, "no probe: its credentials come from the card itself")
        XCTAssertTrue(enablement.knownIDs.contains("llmcenter"))
    }

    /// The other half of the requirement: once the user turns it off, no later launch brings it back.
    /// The id is known by then, so it is never "new" again.
    func testAlwaysSeededProviderStaysOffAfterTheUserTurnsItOff() async {
        let defaults = makeDefaults("always-seeded-off")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(["claude"])
        enablement.registerKnownProviders(["claude"])
        let providers = [probe("claude", hasCredentials: true), probe("llmcenter", hasCredentials: false)]

        await NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)?.value
        XCTAssertTrue(enablement.isEnabled("llmcenter"))

        enablement.setEnabled(false, for: "llmcenter")

        // Two more launches, reading the same persisted store: the choice holds.
        for _ in 0..<2 {
            let relaunched = ProviderEnablementStore(defaults: defaults)
            let task = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: relaunched)
            await task?.value
            XCTAssertFalse(relaunched.isEnabled("llmcenter"), "the user's choice must stick")
        }
    }

    /// The empty-known-set branch baselines without probing, but must still seed the always-on card —
    /// every build that could leave a store in this state predates LLMCenter, so there is no user
    /// choice here to override.
    func testAlwaysSeededProviderIsEnabledEvenWhenBaseliningAnEmptyKnownSet() {
        let enablement = seededStore("always-seeded-baseline", enabled: ["claude"], known: [])
        let grok = probe("grok", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), grok, probe("llmcenter", hasCredentials: false)],
            enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertTrue(enablement.isEnabled("llmcenter"))
        XCTAssertFalse(enablement.isEnabled("grok"), "ordinary providers are still not auto-enabled here")
        XCTAssertEqual(grok.probeCount, 0)
    }

    // MARK: - Helpers

    private func seededStore(_ name: String, enabled: Set<String>, known: Set<String>) -> ProviderEnablementStore {
        let store = ProviderEnablementStore(defaults: makeDefaults(name))
        store.seedEnabledProviders(enabled)
        store.registerKnownProviders(known)
        return store
    }

    private func probe(_ id: String, hasCredentials: Bool) -> ProbeCountingProvider {
        ProbeCountingProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.NewProviderSeeder.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class ProbeCountingProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool
    private(set) var probeCount = 0

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool {
        probeCount += 1
        return hasCredentials
    }
}
