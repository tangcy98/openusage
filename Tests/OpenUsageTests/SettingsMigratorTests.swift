import XCTest
@testable import OpenUsage

final class SettingsMigratorTests: XCTestCase {
    // MARK: - Fresh vs. legacy vs. existing

    /// A genuine first launch (empty domain) records the current schema and runs no migrations — the
    /// stores seed their own current-shape defaults afterward.
    func testFreshInstallStampsCurrentAndRunsNothing() {
        let (defaults, domain) = makeDefaults("Fresh")
        defer { defaults.removePersistentDomain(forName: domain) }

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 3)
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 3)
        XCTAssertNil(ranVersions(defaults), "a fresh install must not run historical migrations")
    }

    /// An install that predates the schema-version key (settings present, no version) is migrated forward
    /// from v0 — every step runs, in order, and existing settings are kept.
    func testLegacyInstallMigratesFromZeroAndKeepsSettings() {
        let (defaults, domain) = makeDefaults("Legacy")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("custom", forKey: "openusage.layout.v1")  // pre-existing settings, no schema version

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 3)
        XCTAssertEqual(ranVersions(defaults), [1, 2, 3])
        XCTAssertEqual(defaults.string(forKey: "openusage.layout.v1"), "custom", "existing settings preserved")
    }

    // MARK: - Cascading

    /// The headline case: a big version jump runs every intermediate step in ascending order and stops
    /// at current — a v7 install opening a v13 build.
    func testCascadeRunsAllIntermediateStepsInOrder() {
        let (defaults, domain) = makeDefaults("Cascade")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(7, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 13, migrations: recording(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13)
        )

        XCTAssertEqual(result, 13)
        XCTAssertEqual(ranVersions(defaults), [8, 9, 10, 11, 12, 13], "only steps above the stored version, in order")
    }

    /// Migrations declared out of order are still applied by ascending version.
    func testStepsApplyInAscendingOrderRegardlessOfDeclaration() {
        let (defaults, domain) = makeDefaults("Order")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 3, migrations: [recordingStep(3), recordingStep(1), recordingStep(2)]
        )

        XCTAssertEqual(ranVersions(defaults), [1, 2, 3])
    }

    /// Already at the current version: nothing runs.
    func testSameVersionIsNoOp() {
        let (defaults, domain) = makeDefaults("Same")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(3, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 3)
        XCTAssertNil(ranVersions(defaults))
    }

    /// A build older than the stored version (downgrade) leaves the recorded version untouched and runs
    /// nothing — old migrations are never replayed backward.
    func testDowngradeLeavesVersionUntouched() {
        let (defaults, domain) = makeDefaults("Downgrade")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(5, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 5)
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 5)
        XCTAssertNil(ranVersions(defaults))
    }

    /// A version bump with no data change for the top step still records reaching `current`, so the
    /// cascade isn't re-evaluated every launch.
    func testReachesCurrentEvenWhenTopVersionsHaveNoStep() {
        let (defaults, domain) = makeDefaults("Gap")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 5, migrations: recording(1, 2)
        )

        XCTAssertEqual(result, 5)
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 5)
        XCTAssertEqual(ranVersions(defaults), [1, 2])
    }

    // MARK: - Resilience

    /// The version is persisted after EACH step, and a failing step stops the cascade at the last
    /// success so the next launch resumes instead of replaying completed steps.
    func testFailureStopsCascadeAndResumesNextLaunch() {
        let (defaults, domain) = makeDefaults("Failure")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 3, migrations: [recordingStep(1), failingStep(2), recordingStep(3)]
        )

        XCTAssertEqual(result, 1, "stops at the last successful step")
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 1)
        XCTAssertEqual(ranVersions(defaults), [1], "the step after the failure does not run")

        // Next launch, failure resolved: resumes from v1 and finishes without replaying v1.
        let resumed = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )
        XCTAssertEqual(resumed, 3)
        XCTAssertEqual(ranVersions(defaults), [1, 2, 3], "resumes at v2; v1 not replayed")
    }

    // MARK: - Regression (the beta-update bug)

    /// The bug this replaces: the old reset wiped the whole domain on every beta bump, silently clearing
    /// `betaUpdatesEnabled` (and everything else) and dropping users off the Early Access channel. The
    /// migrator must NEVER discard settings — an up-to-date install keeps every key untouched.
    func testMigrateNeverWipesExistingSettings() {
        let (defaults, domain) = makeDefaults("NoWipe")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "betaUpdatesEnabled")
        defaults.set("custom", forKey: "openusage.layout.v1")
        defaults.set(720.0, forKey: "openusage.panelHeight")
        defaults.set(SettingsSchema.current, forKey: SettingsMigrator.schemaVersionKey)

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)  // real (shipped) schema

        XCTAssertTrue(defaults.bool(forKey: "betaUpdatesEnabled"), "Early Access opt-in must survive updates")
        XCTAssertEqual(defaults.string(forKey: "openusage.layout.v1"), "custom")
        XCTAssertEqual(defaults.double(forKey: "openusage.panelHeight"), 720.0)
    }

    /// A legacy install (no schema version) running the real, shipped schema keeps its settings while
    /// being migrated forward through every step.
    func testLegacyInstallKeepsSettingsUnderShippedSchema() {
        let (defaults, domain) = makeDefaults("LegacyReal")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "betaUpdatesEnabled")

        let result = SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(result, SettingsSchema.current)
        XCTAssertTrue(defaults.bool(forKey: "betaUpdatesEnabled"))
    }

    // MARK: - v2: enabled-list unification + known-provider set

    /// A legacy disabled-list install converts to the equivalent enabled list: everything on except the
    /// explicitly disabled IDs — behavior-preserving — and the known set records the providers of the
    /// v2 era so none of them is later treated as "new" and probed.
    @MainActor  // `ProviderEnablementStore` (used to verify the migrated shape) is main-actor.
    func testV2ConvertsLegacyDisabledListToEnabledList() {
        let (defaults, domain) = makeDefaults("V2Legacy")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["devin", "grok"], forKey: "openusage.disabledProviders.v1")

        let result = SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(result, SettingsSchema.current)
        let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
        XCTAssertEqual(enabled, Set(SettingsSchema.v2ProviderIDs).subtracting(["devin", "grok"]))
        XCTAssertNil(defaults.stringArray(forKey: "openusage.disabledProviders.v1"), "legacy key removed")
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []),
            Set(SettingsSchema.v2ProviderIDs)
        )

        // The store loads the migrated shape: same effective on/off set, now in enabled-list mode.
        let store = ProviderEnablementStore(defaults: defaults)
        XCTAssertNotNil(store.enabledIDs)
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertFalse(store.isEnabled("devin"))
        XCTAssertFalse(store.isEnabled("grok"))
    }

    /// A legacy install with no disabled providers (the all-on default) converts to all-on.
    func testV2ConvertsAllOnLegacyInstall() {
        let (defaults, domain) = makeDefaults("V2AllOn")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set("custom", forKey: "openusage.layout.v1")  // some settings, so not a fresh install

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            Set(SettingsSchema.v2ProviderIDs)
        )
    }

    /// An install already in enabled-list mode (fresh-installed after first-run detection shipped)
    /// keeps its enabled set untouched and only gains the known set.
    func testV2LeavesExistingEnabledListAloneAndSeedsKnownSet() {
        let (defaults, domain) = makeDefaults("V2EnabledList")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "cursor"], forKey: "openusage.enabledProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            ["claude", "cursor"]
        )
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []),
            Set(SettingsSchema.v2ProviderIDs)
        )
    }

    /// Re-running the v2 step (an interrupted upgrade replays it) changes nothing.
    func testV2IsIdempotent() {
        let (defaults, domain) = makeDefaults("V2Idempotent")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["codex"], forKey: "openusage.disabledProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)
        let enabledAfterFirst = defaults.stringArray(forKey: "openusage.enabledProviders.v1")
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)  // simulate an interrupted upgrade
        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(defaults.stringArray(forKey: "openusage.enabledProviders.v1"), enabledAfterFirst)
    }

    // MARK: - v3: re-offer the always-seeded providers

    /// The rescue case: an install that already ran the build where LLMCenter shipped has it marked
    /// known and left off. Dropping it from the known set is what lets `NewProviderSeeder` see it as new
    /// again on the next launch and seed it on.
    func testV3DropsAlwaysSeededProvidersFromTheKnownSet() {
        let (defaults, domain) = makeDefaults("V3Known")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(2, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "copilot", "llmcenter"], forKey: "openusage.knownProviders.v1")
        defaults.set(["claude", "copilot"], forKey: "openusage.enabledProviders.v1")

        let result = SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(result, SettingsSchema.current)
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []),
            ["claude", "copilot"], "llmcenter is new again"
        )
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            ["claude", "copilot"], "v3 only touches the known set; seeding is NewProviderSeeder's job"
        )
    }

    /// End-to-end: the migration plus the seeder produce the behavior the owner asked for — an updating
    /// user who never signed in still gets the LLMCenter card.
    @MainActor
    func testV3AndSeederTogetherRestoreTheLLMCenterCard() async {
        let (defaults, domain) = makeDefaults("V3EndToEnd")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(2, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "copilot", "llmcenter"], forKey: "openusage.knownProviders.v1")
        defaults.set(["claude", "copilot"], forKey: "openusage.enabledProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        let enablement = ProviderEnablementStore(defaults: defaults)
        XCTAssertFalse(enablement.isEnabled("llmcenter"), "still off as the store loads")

        let providers = ProviderCatalog.make(defaults: defaults)
        await NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)?.value

        XCTAssertTrue(enablement.isEnabled("llmcenter"))
        XCTAssertTrue(enablement.isEnabled("claude"), "existing choices are untouched")
    }

    /// Re-running the v3 step (an interrupted upgrade replays it) changes nothing, and a later launch
    /// must not undo a user who turned the provider off after the rescue.
    func testV3IsIdempotentAndDoesNotReRunOnALaterLaunch() {
        let (defaults, domain) = makeDefaults("V3Idempotent")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(2, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "llmcenter"], forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)
        defaults.set(2, forKey: SettingsMigrator.schemaVersionKey)  // simulate an interrupted upgrade
        SettingsMigrator.migrate(defaults: defaults, domainName: domain)
        XCTAssertEqual(Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []), ["claude"])

        // A later launch is already at `current`: the step does not run again, so a provider the user
        // turned off (and that is known again by now) is not re-offered a second time.
        defaults.set(["claude", "llmcenter"], forKey: "openusage.knownProviders.v1")
        SettingsMigrator.migrate(defaults: defaults, domainName: domain)
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []),
            ["claude", "llmcenter"], "the rescue is one-shot"
        )
    }

    /// A fresh install stamps v3 and runs nothing — `FirstRunSeeder` already forces the card on there.
    func testV3DoesNotRunOnAFreshInstall() {
        let (defaults, domain) = makeDefaults("V3Fresh")
        defer { defaults.removePersistentDomain(forName: domain) }

        let result = SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(result, SettingsSchema.current)
        XCTAssertNil(defaults.stringArray(forKey: "openusage.knownProviders.v1"))
    }

    /// The frozen v3 list must stay a subset of the live always-seeded set, or the migration would
    /// re-offer a provider the seeder no longer forces on (leaving it off and looking like a bug).
    @MainActor
    func testV3ListMatchesTheLiveAlwaysSeededSet() {
        XCTAssertTrue(
            Set(SettingsSchema.v3AlwaysSeededProviderIDs).isSubset(of: FirstRunSeeder.alwaysSeededProviderIDs),
            "a provider dropped from alwaysSeededProviderIDs must also leave the v3 migration list"
        )
    }

    // MARK: - Schema integrity

    /// Guards against editing the migration list without bumping `current` (or vice versa): every
    /// migration targets a unique version in `1...current`, and `current` is at least the highest one.
    func testShippedSchemaIsConsistent() {
        let versions = SettingsSchema.migrations.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count, "migration versions must be unique")
        XCTAssertGreaterThanOrEqual(
            SettingsSchema.current, versions.max() ?? SettingsSchema.current,
            "bump SettingsSchema.current when you add a migration"
        )
        for version in versions {
            XCTAssertGreaterThanOrEqual(version, 1, "schema versions start at 1")
            XCTAssertLessThanOrEqual(version, SettingsSchema.current)
        }
    }

    // MARK: - Helpers

    private static let ranKey = "test.ran"

    private func makeDefaults(_ name: String) -> (UserDefaults, String) {
        let suite = "OpenUsageTests.SettingsMigrator.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    /// A migration that appends its version to a list in `defaults`, so a test can assert exactly which
    /// steps ran and in what order.
    private func recordingStep(_ version: Int) -> SettingsMigration {
        SettingsMigration(version: version) { defaults in
            var ran = defaults.array(forKey: Self.ranKey) as? [Int] ?? []
            ran.append(version)
            defaults.set(ran, forKey: Self.ranKey)
        }
    }

    private func recording(_ versions: Int...) -> [SettingsMigration] {
        versions.map(recordingStep)
    }

    /// A migration that always throws, to exercise the stop-and-resume path.
    private func failingStep(_ version: Int) -> SettingsMigration {
        SettingsMigration(version: version) { _ in throw MigrationTestError.boom }
    }

    /// The recorded run order, or `nil` if no step ran.
    private func ranVersions(_ defaults: UserDefaults) -> [Int]? {
        defaults.array(forKey: Self.ranKey) as? [Int]
    }

    private enum MigrationTestError: Error { case boom }
}
