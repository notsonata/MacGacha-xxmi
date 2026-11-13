// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import Launch
import LauncherCore
import ModSupport
import RuntimeManager
@testable import MacGacha

/// The signed catalog recommends a newer D3DMetal Wine than the only one XXMI
/// injection is verified on. While any supported game injects, automatic
/// updates must not replace or remove the verified bundle.
@Suite(.timeLimit(.minutes(1))) @MainActor struct XXMIRuntimeUpdateTests {
    private func setInjection(_ enabled: Bool, game: String = "starrail", _ f: BundleUpgradeFixture) async throws {
        let store = try #require(f.model.modSupportStores[game])
        try await store.setInjectionEnabled(enabled, acknowledgingRisk: true)
    }

    private func selected(_ f: BundleUpgradeFixture, _ backend: RuntimeBackend = .d3dmetal) -> String? {
        f.model.runtimeCatalog?.selectedBundle(for: backend)?.id.rawValue
    }

    @Test(arguments: ["starrail", "zzz"]) func injectingGameKeepsTheVerifiedBundleSelected(game: String) async throws {
        let f = try await BundleUpgradeFixture.make()
        try await setInjection(true, game: game, f)
        f.model.autoUpdateDependencies = true
        try #require(f.model.dependencyAutoUpdateTask != nil)
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        #expect(selected(f) == f.old)
        #expect(!f.model.runtimeIsPinned(f.old))
        #expect(f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == nil)
        #expect(f.model.dependencyConsentTargets.isEmpty)
        #expect(f.model.runtimeCatalogMutationID == nil)
    }

    @Test func vanillaUsersStillReceiveTheAutomaticUpgrade() async throws {
        let f = try await BundleUpgradeFixture.make()
        // A previously enabled, now disabled mod preference gives no protection.
        try await setInjection(true, f)
        try await setInjection(false, f)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(selected(f) == f.new)
    }

    @Test func updatesForOtherBackendsStillProceedWhileModsInject() async throws {
        let f = try await BundleUpgradeFixture.make()
        try await setInjection(true, f)
        let oldDXMT = try #require(selected(f, .dxmt))
        let newDXMT = "dxmt-wine11.20mg1.0-dxmt0.80"
        try #require(oldDXMT != newDXMT)
        try f.publish(oldDXMT)
        try await f.model.scanAndApply()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == newDXMT)
        try f.publish(newDXMT); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(selected(f, .dxmt) == newDXMT)
        #expect(selected(f) == f.old)
        #expect(f.services.snapshot.bundleInstalls == [newDXMT])
    }

    @Test func enablingModsWhileTheUpgradeIsStagingStopsBeforeActivation() async throws {
        let f = try await BundleUpgradeFixture.make()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        let task = try #require(f.model.dependencyAutoUpdateTask)
        f.model.setModSupportInjection(true, acknowledgingRisk: true)
        await f.model.modSupportTasks["starrail"]?.value
        try f.publish(f.new); f.services.emit(.phase(.completed))
        await task.value
        #expect(selected(f) == f.old)
        #expect(f.model.runtimeCatalogMutationID == nil)
        #expect(f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == nil)
        #expect(!f.model.dependencyHasRetainedVersions)
    }

    @Test func activationWaitsForInFlightModSupportWork() async throws {
        let f = try await BundleUpgradeFixture.make()
        f.model.modSupportActivities["starrail"] = .saving
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .waitingToActivate(id: f.new) }
        // Only a failing guard can end this early, so a bound is safe for correctness.
        for _ in 0..<50 where selected(f) == f.old { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selected(f) == f.old)
        #expect(f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .waitingToActivate(id: f.new))
        f.model.modSupportActivities["starrail"] = nil
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(selected(f) == f.new)
    }

    @Test func unreadableModStateFailsClosedUntilItIsReadableAgain() async throws {
        let f = try await BundleUpgradeFixture.make()
        try await setInjection(true, f)
        let state = f.paths.root.appendingPathComponent("XXMI/Games/starrail/state.json")
        try #require(FileManager.default.fileExists(atPath: state.path))
        try Data("not json".utf8).write(to: state)
        f.model.autoUpdateDependencies = true
        try #require(f.model.dependencyAutoUpdateTask != nil)
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        #expect(selected(f) == f.old)

        try FileManager.default.removeItem(at: state)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.scheduleDependencyAutoUpdates(retry: true)
        #expect(await events.next() == f.new)
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(selected(f) == f.new)
    }

    @Test func turningInjectionOffLetsThePausedUpgradeProceed() async throws {
        let f = try await BundleUpgradeFixture.make()
        try await setInjection(true, f)
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.setModSupportInjection(false, acknowledgingRisk: false)
        #expect(await events.next() == f.new)
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(selected(f) == f.new)
    }

    @Test func explicitNewerSelectionIsHonoredAndStaysIneligible() async throws {
        let f = try await BundleUpgradeFixture.make()
        try await setInjection(true, f)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.useRuntimeVersion(f.new, pinned: false)
        #expect(await events.next() == f.new)
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { f.model.runtimeCatalogMutationID == nil }
        #expect(selected(f) == f.new)
        var settings = LaunchSettings.defaults(for: "starrail")
        settings.backend = .d3dmetal
        f.model.launchSettingsCache["starrail"] = settings
        #expect(f.model.modSupportRuntimeIneligible(for: "starrail"))
        // Returning to the verified bundle is an explicit pin the guard never touches.
        f.model.useRuntimeVersion(f.old)
        await f.model.catalogMutationTask?.value
        #expect(selected(f) == f.old)
        #expect(f.model.runtimeIsPinned(f.old))
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        #expect(selected(f) == f.old)
    }

    @Test func cleanupKeepsTheVerifiedBundleWhileModsInjectAndResumesAfterwards() async throws {
        let f = try await BundleUpgradeFixture.make()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        _ = await events.next()
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        f.model.autoUpdateDependencies = false
        #expect(selected(f) == f.new)
        let store = RuntimeAutomaticUpdateStore(paths: f.paths)
        try await BlockingIO.run { try store.recordVerifiedSession(bundleID: f.new, componentIDs: [], confirmedRunningSeconds: 120, sessionID: UUID()) }

        try await setInjection(true, f)
        f.model.scheduleDependencyAutoUpdates()
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.services.snapshot.bundles[f.old] != nil)
        #expect(try await BlockingIO.run { try store.load().replacements.count } == 1)

        f.model.setModSupportInjection(false, acknowledgingRisk: false)
        await f.model.modSupportTasks["starrail"]?.value
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.services.snapshot.bundles[f.old] == nil)
        #expect(f.services.snapshot.bundles[f.new] != nil)
        #expect(try await BlockingIO.run { try store.load().replacements.isEmpty })
    }

    @Test func consentSetupCannotCaptureATargetWhileInjectionIsBeingEnabled() async throws {
        let f = try await BundleUpgradeFixture.make()
        f.services.state.withLock { $0.accepted = false }
        try await f.model.scanAndApply()
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        var settings = f.model.launchSettings(for: "genshin"); settings.backend = .d3dmetal
        f.model.launchSettingsCache["genshin"] = settings
        f.model.refreshDependencyConsentGames()
        try #require(f.model.dependencyConsentTargets[.d3dmetal] != nil)
        f.model.setModSupportInjection(true, acknowledgingRisk: true)
        f.model.installRecommended(for: "genshin")
        await f.model.modSupportTasks["starrail"]?.value
        #expect(f.model.catalogActivationTargets["genshin"] == nil)
        #expect(f.model.runtimeCatalogMutationID == nil)
        #expect(selected(f) == f.old)
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        f.model.cancelRuntimeSetup(for: "genshin")
        await f.model.runtimeSetupRosettaChecks["genshin"]?.task.value
    }


    @Test func capturedConsentSetupRechecksDurableInjectionBeforeActivation() async throws {
        let f = try await BundleUpgradeFixture.make()
        try f.publish(f.new)
        try await f.model.scanAndApply()
        let target = try f.model.runtimeVersionTarget(f.new, pinned: false)
        f.model.runtimeCatalogMutationID = f.new
        f.model.catalogActivationTargets["genshin"] = target
        f.model.automaticCatalogSetupKeys.insert("genshin")
        // Model a toggle already in flight before setup reserved the catalog.
        try await setInjection(true, f)
        f.model.finishCatalogSetup("genshin", succeeded: true)
        await f.model.catalogMutationTask?.value
        #expect(selected(f) == f.old)
        #expect(f.model.runtimeCatalogMutationID == nil)
        #expect(f.model.automaticCatalogSetupKeys.isEmpty)
        #expect(f.model.catalogActivationTargets.isEmpty)
    }

}
