// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import GameLibrary
@testable import RuntimeManager
import TestSupport
@testable import Launch

private let nativeBundleID = "d3dmetal-wine11.20-gptk4.0b3"
private let builtinD3D11 = Data("wine builtin d3d11".utf8)
private let builtinCompiler = Data("wine builtin d3dcompiler_47".utf8)
private let proxyD3D11 = Data("native proxy d3d11".utf8)

private final class NativeOrder: Sendable {
    private let values = Mutex<[String]>([])
    func append(_ value: String) { values.withLock { $0.append(value) } }
    var all: [String] { values.withLock { $0 } }
}

/// Fake idle-prefix preparation with the registry reconciliation half. It
/// records every call and never starts anything.
private final class NativePreparation: LaunchPreparing, LaunchNativeProxyOverridePreparing, Sendable {
    let order: NativeOrder
    private let failure = Mutex<(enabled: Bool, error: LauncherError)?>(nil)
    private let calls = Mutex<[Bool]>([])
    init(order: NativeOrder) { self.order = order }
    var reconciled: [Bool] { calls.withLock { $0 } }
    func fail(enabled: Bool) { failure.withLock { $0 = (enabled, .io("injected registry failure")) } }
    func ensure(prefix: URL, wineBinary: URL, request: PreparationRequest) async throws -> PreparationOutcome {
        order.append("ensure"); return PreparationOutcome()
    }
    func reconcileNativeProxyOverrides(prefix: URL, wineBinary: URL, enabled: Bool) async throws -> NativeProxyOverrideOutcome {
        calls.withLock { $0.append(enabled) }
        order.append("reconcile:\(enabled)")
        if let failure = failure.withLock({ $0 }), failure.enabled == enabled { throw failure.error }
        return NativeProxyOverrideOutcome(action: enabled ? .applied : .unchanged, residualKeys: [])
    }
}

private final class NativeProvider: LaunchInjectionPreparing, Sendable {
    private struct State {
        var configuration: LaunchInjectionConfiguration?
        var finished: [LaunchInjectionConfiguration] = []
        var discarded: [LaunchInjectionConfiguration] = []
        var swept: [String: [URL]] = [:]
        var onFinish: (@Sendable () -> Void)?
    }
    private let state: Mutex<State>
    let order: NativeOrder
    init(_ configuration: LaunchInjectionConfiguration?, order: NativeOrder) {
        state = Mutex(State(configuration: configuration)); self.order = order
    }
    var finished: [LaunchInjectionConfiguration] { state.withLock { $0.finished } }
    var discarded: [LaunchInjectionConfiguration] { state.withLock { $0.discarded } }
    var swept: [String: [URL]] { state.withLock { $0.swept } }
    func onFinish(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.onFinish = action } }
    func prepare(gameID: String, runtimeBundleID: String, backendD3D11: URL) async throws -> LaunchInjectionConfiguration? {
        order.append("prepareInjection")
        return state.withLock { $0.configuration }
    }
    func finish(configuration: LaunchInjectionConfiguration) async throws {
        order.append("finish")
        let action = state.withLock { state in
            state.finished.append(configuration); defer { state.onFinish = nil }; return state.onFinish
        }
        action?()
    }
    func discard(configuration: LaunchInjectionConfiguration) async { state.withLock { $0.discarded.append(configuration) } }
    func sweepSessions(gameID: String, retaining: [URL]) async { state.withLock { $0.swept[gameID] = retaining } }
}

/// A ZZZ launch environment on the verified runtime with a real owned prefix
/// system32, a real immutable native session snapshot and fake processes.
private final class NativeFixture: Sendable {
    let base: ManagerFixture
    let order = NativeOrder()
    let preparation: NativePreparation
    let selection: LaunchRuntimeSelection
    let configuration: LaunchInjectionConfiguration
    let settings = LaunchSettings(backend: .d3dmetal, retina: false, frameLimit: nil, directX12: false, compatibilityPatches: false)
    let game = GameDefinition.find("zzz")!
    let spawner = ManagerSpawner()
    var system32: URL { base.prefix.appendingPathComponent("drive_c/windows/system32") }
    var payload: URL { configuration.sessionDirectory.appendingPathComponent("payload") }

    init(directX12: Bool = false) async throws {
        base = try await ManagerFixture.make(initialGame: false)
        preparation = NativePreparation(order: order)
        let f = base
        (selection, configuration) = try await BlockingIO.run {
            let fm = FileManager.default
            let dosdevices = f.prefix.appendingPathComponent("dosdevices", isDirectory: true)
            try fm.createDirectory(at: dosdevices, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: dosdevices.appendingPathComponent("z:").path, withDestinationPath: "/")
            let system32 = f.prefix.appendingPathComponent("drive_c/windows/system32")
            try builtinD3D11.write(to: system32.appendingPathComponent("d3d11.dll"))
            try builtinCompiler.write(to: system32.appendingPathComponent("d3dcompiler_47.dll"))
            try Data("unrelated".utf8).write(to: system32.appendingPathComponent("kernel32.dll"))
            try Data("game".utf8).write(to: f.installRoot.appendingPathComponent("ZenlessZoneZero.exe"))
            let root = f.paths.runtimes.appendingPathComponent("bundles/verified", isDirectory: true)
            let windows = root.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
            try fm.createDirectory(at: windows, withIntermediateDirectories: true)
            try Data("d3d11".utf8).write(to: windows.appendingPathComponent("d3d11.dll"))
            let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(nativeBundleID), root: root,
                wineBinary: root.appendingPathComponent("bin/wine"), digest: f.bundle.digest, source: .download)
            let selection = LaunchRuntimeSelection(bundle: bundle, componentIDs: f.runtime.selected.componentIDs,
                componentRoots: f.runtime.selected.componentRoots, compatibilityComponentIDs: f.runtime.selected.compatibilityComponentIDs)
            let session = f.paths.root.appendingPathComponent("XXMI/Sessions/zzz/\(UUID().uuidString)", isDirectory: true)
            let payload = session.appendingPathComponent("payload", isDirectory: true)
            try fm.createDirectory(at: payload.appendingPathComponent("Core/ZZMI"), withIntermediateDirectories: true)
            try fm.createDirectory(at: payload.appendingPathComponent("Mods/Example"), withIntermediateDirectories: true)
            try Data("core".utf8).write(to: payload.appendingPathComponent("Core/ZZMI/main.ini"))
            try proxyD3D11.write(to: payload.appendingPathComponent("d3d11.dll"))
            try Data("native compiler".utf8).write(to: payload.appendingPathComponent("d3dcompiler_47.dll"))
            try Data("[Loader]\n".utf8).write(to: payload.appendingPathComponent("d3dx.ini"))
            for file in ["hook-runner.exe", "3dmloader.dll"] { try Data(file.utf8).write(to: session.appendingPathComponent(file)) }
            let configuration = LaunchInjectionConfiguration(runnerURL: session.appendingPathComponent("hook-runner.exe"),
                injectorURL: session.appendingPathComponent("3dmloader.dll"), payloadURL: payload.appendingPathComponent("d3d11.dll"),
                sessionDirectory: session.standardizedFileURL, gameID: "zzz", targetExecutable: "ZenlessZoneZero.exe", loading: .nativeProxy)
            return (selection, configuration)
        }
        var settings = settings; settings.directX12 = directX12
        try await BlockingIO.run { [settings] in try LaunchSettingsStore(paths: f.paths).save(settings, for: "zzz") }
        let spawner = spawner, order = order, system32 = system32
        spawner.afterSpawn {
            // The payload must already be in place when the game starts.
            let placed = (try? Data(contentsOf: system32.appendingPathComponent("d3d11.dll"))) == proxyD3D11
            order.append(placed ? "spawn:placed" : "spawn:unplaced")
            f.inspector.update {
                $0.processes = [InspectedProcess(identity: spawner.identity, executablePath: "/wine/ZenlessZoneZero.exe", arguments: [])]
                $0.alive = [spawner.identity]
            }
        }
    }

    func manager(provider: NativeProvider?, preparation: (any LaunchPreparing)? = nil,
        files: NativeProxyFiles = NativeProxyFiles(), harvester: NativeProxyLogHarvester = NativeProxyLogHarvester()) -> LaunchManager {
        LaunchManager(paths: base.paths, runtimes: ManagerRuntimeProvider(selected: selection), prefixes: base.prefixes,
            preparation: preparation ?? self.preparation, spawner: spawner, inspector: base.inspector, runner: base.runner, clock: base.clock,
            log: nil, displayProbe: FixedDisplayProbe(),
            proxyFactory: { [proxy = base.proxy] _, log in proxy.start(log: log); return proxy },
            baseEnvironment: [:], journalFileOps: base.journalOps, hideHooks: .none,
            beforeJournalRead: {}, beforeRecoveryRead: {}, recipeOverrides: [:],
            sessionProvenance: { (ManagerFixture.bootSessionUUID, ManagerFixture.sessionStartTime) },
            beforeSessionLogWrite: {}, injectionPreparation: provider, nativeProxyFiles: files,
            nativeLogHarvester: harvester)
    }

    func launch(_ manager: LaunchManager, events: ManagerEvents) async -> Task<Void, Never> {
        let stream = await manager.launch(game: game, installRoot: base.installRoot, gameBuild: "3.3.0")
        return Task { for await event in stream { await events.append(event) } }
    }

    func journal() async throws -> LaunchSession? {
        try await BlockingIO.run { try LaunchJournal(paths: self.base.paths).read(game: "zzz") }
    }
    func rawJournal() async throws -> String? {
        let url = base.paths.root.appendingPathComponent("Games/zzz/launch-session.json")
        return try await BlockingIO.run { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Every system32 entry by name, without following links.
    func system32Listing() throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: system32.path) {
            let url = system32.appendingPathComponent(name)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                result[name] = "link:" + target
            } else if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                result[name] = "directory"
            } else {
                result[name] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            }
        }
        return result
    }
    var baseline: [String: String] {
        ["d3d11.dll": "wine builtin d3d11", "d3dcompiler_47.dll": "wine builtin d3dcompiler_47", "kernel32.dll": "unrelated"]
    }

    /// A journal exactly as a crashed instance leaves it after placement.
    func crashedSession(processes: [ProcessIdentity]) async throws -> LaunchSession {
        let f = base, configuration = configuration, settings = settings, selection = selection
        return try await BlockingIO.run {
            var session = LaunchSession(sessionID: UUID(), game: "zzz", installRoot: f.installRoot,
                installIdentity: try ContainedFileSystem(root: f.installRoot).rootIdentity(), prefix: f.prefix,
                bundleID: selection.bundle.id.rawValue, runtimeDigest: selection.bundle.digest, wineBinary: selection.bundle.wineBinary,
                wineserver: selection.bundle.wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver"),
                componentIDs: selection.componentIDs, recipeVersion: 1, settings: settings, state: .running, processes: processes,
                gameExecutable: try SafeRelativePath("ZenlessZoneZero.exe"), bootSessionUUID: ManagerFixture.bootSessionUUID,
                sessionStartTime: ManagerFixture.sessionStartTime, reachedRunning: true, injection: configuration)
            let journal = LaunchJournal(paths: f.paths)
            try journal.write(session)
            var record: NativeProxyRecord?
            try NativeProxyFiles().place(sessionDirectory: configuration.sessionDirectory, prefix: f.prefix.standardizedFileURL,
                sessionID: session.sessionID, record: &record) { next in
                session.nativeProxy = next; try journal.write(session)
            }
            return session
        }
    }

    func resolvedCommand() throws -> ResolvedLaunch {
        try LaunchResolver.resolve(recipe: try #require(Recipes.recipe(for: "zzz")), settings: settings,
            installRoot: base.installRoot, prefix: base.prefix, wineBinary: selection.bundle.wineBinary, proxyPort: base.proxy.port,
            componentRoots: selection.componentRoots, baseEnvironment: [:], runtimeBundleID: selection.bundle.id.rawValue)
    }
}

private func failed(_ event: LaunchEvent) -> Bool { if case .failed = event { true } else { false } }

/// Throws `SimulatedStop` once at `step`, modelling an interrupted transaction.
private func stopping(at step: NativeProxyFileStep) -> NativeProxyFiles {
    let fired = Mutex(false)
    return NativeProxyFiles(hook: { current in
        guard current == step, fired.withLock({ let was = $0; $0 = true; return !was }) else { return }
        throw LauncherError.io("injected native proxy interruption")
    })
}

@Suite(.timeLimit(.minutes(1))) struct NativeProxyManagerTests {
    @Test func modsOnPlacesBeforeSpawnKeepsTheCommandAndRestoresTheExactBaseline() async throws {
        let n = try await NativeFixture()
        let provider = NativeProvider(n.configuration, order: n.order)
        let manager = n.manager(provider: provider)
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.waitForRunning()

        #expect(n.order.all == ["ensure", "prepareInjection", "reconcile:true", "spawn:placed"])
        let call = try #require(n.spawner.calls.first)
        let original = try n.resolvedCommand()
        #expect(n.spawner.calls.count == 1)
        #expect(call.executable == original.executable)
        #expect(call.arguments == original.arguments)
        #expect(call.environment == original.environment)
        #expect(!call.arguments.contains { $0.contains("hook-runner") || $0 == "--loader" })

        let journal = try #require(try await n.journal())
        let record = try #require(journal.nativeProxy)
        #expect(record.phase == .placed)
        #expect(record.sessionDirectory.path == n.configuration.sessionDirectory.path)
        #expect(journal.injection == n.configuration)
        let placed = try n.system32Listing()
        #expect(placed["d3d11.dll"] == "native proxy d3d11")
        #expect(placed["d3dx.ini"] == "[Loader]\n")
        #expect(placed["Core"] == "link:" + n.payload.appendingPathComponent("Core").path)
        #expect(placed["Mods"] == "link:" + n.payload.appendingPathComponent("Mods").path)
        #expect(placed["d3d11.dll.macgacha-hidden-\(journal.sessionID.uuidString)"] == "wine builtin d3d11")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: n.base.prefix.appendingPathComponent("dosdevices/m:").path)
            == n.configuration.sessionDirectory.deletingLastPathComponent().path)
        // A watcher persist while running keeps the durable record unchanged.
        await n.base.clock.waitForSleep(1, duration: .seconds(3))
        #expect(try await n.journal()?.nativeProxy == record)

        try await n.base.end(manager); await consumer.value
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
        #expect(provider.finished == [n.configuration])
        #expect(n.order.all.suffix(1) == ["finish"])
        // Registry ownership is reconciled at the next idle launch, never at end.
        #expect(n.preparation.reconciled == [true])
        let restoredEvents = await events.values
        #expect(restoredEvents.contains { if case .restored(.clean) = $0 { true } else { false } })
    }

    @Test func modsOffWithoutOwnershipStaysInertAndKeepsTheJournalBytes() async throws {
        let n = try await NativeFixture()
        let provider = NativeProvider(nil, order: n.order)
        let manager = n.manager(provider: provider)
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.waitForRunning()
        #expect(n.order.all == ["ensure", "prepareInjection", "reconcile:false", "spawn:unplaced"])
        let call = try #require(n.spawner.calls.first)
        #expect(call.arguments == (try n.resolvedCommand()).arguments)
        #expect(try n.system32Listing() == n.baseline)
        let raw = try #require(try await n.rawJournal())
        #expect(!raw.contains("nativeProxy"))
        #expect(!raw.contains("injection"))
        try await n.base.end(manager); await consumer.value
        #expect(try await n.journal() == nil)
        #expect(n.preparation.reconciled == [false])
    }

    @Test func modsOffWithAPreparationThatCannotOwnOverridesMakesNoRegistryCall() async throws {
        let n = try await NativeFixture()
        let manager = n.manager(provider: nil, preparation: n.base.preparation)
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.waitForRunning()
        #expect(n.spawner.calls.first?.arguments == (try n.resolvedCommand()).arguments)
        try await n.base.end(manager); await consumer.value
        #expect(try n.system32Listing() == n.baseline)
    }

    @Test func ownedModsOffCleanupFailureFailsClosedBeforeSpawn() async throws {
        let n = try await NativeFixture()
        n.preparation.fail(enabled: false)
        let manager = n.manager(provider: NativeProvider(nil, order: n.order))
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.wait(for: failed); await consumer.value
        #expect(n.spawner.calls.isEmpty)
        #expect(try await n.journal() == nil)
        #expect(try n.system32Listing() == n.baseline)
    }

    @Test func nativeModsOnFailsClosedWithoutRegistryOwnershipOrOnOverrideFailure() async throws {
        for failing in [false, true] {
            let n = try await NativeFixture()
            if failing { n.preparation.fail(enabled: true) }
            let provider = NativeProvider(n.configuration, order: n.order)
            let manager = n.manager(provider: provider, preparation: failing ? nil : n.base.preparation)
            let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
            await events.wait(for: failed); await consumer.value
            #expect(n.spawner.calls.isEmpty)
            #expect(try n.system32Listing() == n.baseline)
            #expect(try await n.journal() == nil)
            // The snapshot reached the journal, so it is harvested, not discarded.
            #expect(provider.finished == [n.configuration])
        }
    }

    @Test func directX12IsNeverChangedAndRefusesNativeLoading() async throws {
        let n = try await NativeFixture(directX12: true)
        let manager = n.manager(provider: NativeProvider(n.configuration, order: n.order))
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.wait(for: failed); await consumer.value
        #expect(n.spawner.calls.isEmpty)
        #expect(n.preparation.reconciled.isEmpty)
        #expect(try await BlockingIO.run { try LaunchSettingsStore(paths: n.base.paths).load("zzz") }.directX12)
        #expect(try n.system32Listing() == n.baseline)
    }

    @Test func newZZZHookRunnerSnapshotIsRefusedAndDiscarded() async throws {
        let n = try await NativeFixture()
        let hook = LaunchInjectionConfiguration(runnerURL: n.configuration.runnerURL, injectorURL: n.configuration.injectorURL,
            payloadURL: n.configuration.payloadURL, sessionDirectory: n.configuration.sessionDirectory,
            gameID: "zzz", targetExecutable: "ZenlessZoneZero.exe")
        let provider = NativeProvider(hook, order: n.order)
        let manager = n.manager(provider: provider)
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.wait(for: failed); await consumer.value
        #expect(n.spawner.calls.isEmpty)
        #expect(provider.discarded == [hook])
        #expect(n.preparation.reconciled.isEmpty)
        #expect(try await n.journal() == nil)
    }

    @Test(arguments: [NativeProxyFileStep.afterPlanPersist, .afterHideRename, .afterHidePersist, .afterStageCreate,
        .afterPublish, .afterLinkCreate, .afterPlacedPersist])
    func interruptedPlacementRestoresTheBaselineWithoutSpawning(_ step: NativeProxyFileStep) async throws {
        let n = try await NativeFixture()
        let provider = NativeProvider(n.configuration, order: n.order)
        let manager = n.manager(provider: provider, files: stopping(at: step))
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.wait(for: failed); await consumer.value
        #expect(n.spawner.calls.isEmpty)
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
        #expect(provider.finished == [n.configuration])
        let values = await events.values
        let failure = try #require(values.compactMap { if case .failed(let value) = $0 { value } else { nil } }.first)
        #expect(failure.stage == .spawn)
    }

    @Test(arguments: [NativeProxyFileStep.afterHideRename, .afterPublish, .afterLinkCreate])
    func journalFailureAfterADiskMutationKeepsTheNewestRecord(_ step: NativeProxyFileStep) async throws {
        let n = try await NativeFixture()
        let journalOps = n.base.journalOps
        // The next journal publication after this mutation fails: memory is
        // newer than the journal, and restore must still own the mutation.
        let files = NativeProxyFiles(hook: { if $0 == step { journalOps.arm() } })
        let manager = n.manager(provider: NativeProvider(n.configuration, order: n.order), files: files)
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.wait(for: failed); await consumer.value
        #expect(n.spawner.calls.isEmpty)
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
    }

    @Test func spawnFailureRestoresPlacedFiles() async throws {
        let n = try await NativeFixture()
        n.spawner.fail()
        let manager = n.manager(provider: NativeProvider(n.configuration, order: n.order))
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.wait(for: failed); await consumer.value
        #expect(n.spawner.calls.count == 1)
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
    }

    @Test func watchUncertaintyAndALingeringHelperRetainPlacedFiles() async throws {
        let n = try await NativeFixture()
        let f = n.base
        let manager = n.manager(provider: NativeProvider(n.configuration, order: n.order))
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.waitForRunning(); await f.clock.waitForSleep(1, duration: .seconds(3))
        let placed = try n.system32Listing()
        f.inspector.update { $0.failure = true }; f.clock.advance(by: .seconds(3))
        await f.clock.waitForSleep(1, duration: .seconds(1))
        #expect(try await n.journal()?.state == .recoveryPending)
        #expect(try await n.journal()?.nativeProxy?.phase == .placed)
        #expect(try n.system32Listing() == placed)
        await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "zzz") }
        // The game exits but a prefix helper lingers: still not a verified end.
        let helper = InspectedProcess(identity: ProcessIdentity(pid: 34567, startTime: 300), executablePath: "/wine/bin/wineserver", arguments: [])
        f.inspector.update { $0.failure = false; $0.processes = [helper]; $0.alive = [] }
        f.clock.advance(by: .seconds(1))
        await f.clock.waitForSleep(2, duration: .seconds(3))
        f.clock.advance(by: .seconds(3))
        await f.clock.waitForSleep(3, duration: .seconds(3))
        #expect(try n.system32Listing() == placed)
        #expect(try await n.journal()?.nativeProxy?.phase == .placed)
        f.inspector.update { $0.processes = [] }
        f.clock.advance(by: .seconds(3))
        await consumer.value
        await manager.waitForSupervision(game: "zzz")
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
    }

    @Test func foreignReplacementIsRetainedAsPendingUntilResolved() async throws {
        let n = try await NativeFixture()
        let manager = n.manager(provider: NativeProvider(n.configuration, order: n.order))
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.waitForRunning()
        let sessionID = try #require(try await n.journal()).sessionID
        // Something else replaces our placed DLL while the game runs.
        let d3d11 = n.system32.appendingPathComponent("d3d11.dll")
        try FileManager.default.removeItem(at: d3d11)
        try Data("foreign".utf8).write(to: d3d11)
        try await n.base.end(manager); await consumer.value
        await manager.waitForSupervision(game: "zzz")

        let pending = try #require(try await n.journal())
        #expect(pending.state == .recoveryPending)
        #expect(pending.nativeProxy?.phase == .restoring)
        let listing = try n.system32Listing()
        #expect(listing["d3d11.dll"] == "foreign")
        #expect(listing["d3d11.dll.macgacha-hidden-\(sessionID.uuidString)"] == "wine builtin d3d11")
        let values = await events.values
        #expect(!values.contains { if case .restored(.clean) = $0 { true } else { false } })
        #expect(values.contains { if case .restored(.pending) = $0 { true } else { false } })
        await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "zzz") }

        try FileManager.default.removeItem(at: d3d11)
        try await manager.recoverIfNeeded(game: "zzz")
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
    }

    @Test func journalDeletionFailureNeverResurrectsAClearedRecord() async throws {
        let n = try await NativeFixture()
        let manager = n.manager(provider: NativeProvider(n.configuration, order: n.order))
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.waitForRunning()
        n.base.journalOps.armDelete()
        try await n.base.end(manager); await consumer.value
        await manager.waitForSupervision(game: "zzz")
        let resolved = try #require(try await n.journal())
        #expect(resolved.nativeProxy == nil)
        #expect(resolved.hides.isEmpty)
        #expect(try n.system32Listing() == n.baseline)
        try await manager.recoverIfNeeded(game: "zzz")
        #expect(try await n.journal() == nil)
        #expect(try n.system32Listing() == n.baseline)
    }

    @Test func reattachRestoresFromTheRecordedContextWithAReclaimedSnapshot() async throws {
        let n = try await NativeFixture()
        // A crashed instance left a placed session; the game has since ended
        // and the snapshot directory was reclaimed, leaving dangling links.
        let crashed = try await n.crashedSession(processes: [ProcessIdentity(pid: 45678, startTime: 400)])
        #expect(crashed.nativeProxy?.phase == .placed)
        try FileManager.default.removeItem(at: n.configuration.sessionDirectory)
        // An instance without mod support restores files without starting Wine.
        let later = n.manager(provider: nil, preparation: n.base.preparation)
        let startup = await later.reattachStartup()
        #expect(startup.sessions["zzz"] == nil)
        #expect(startup.unresolved.isEmpty)
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
        #expect(n.spawner.calls.isEmpty)
        #expect(n.preparation.reconciled.isEmpty)
    }

    @Test func reattachRetainsAReferencedSnapshotAndRestoresAfterVerifiedEnd() async throws {
        let n = try await NativeFixture()
        let game = InspectedProcess(identity: ProcessIdentity(pid: 45678, startTime: 400), executablePath: "/wine/ZenlessZoneZero.exe", arguments: [])
        n.base.inspector.update { $0.processes = [game]; $0.alive = [game.identity] }
        _ = try await n.crashedSession(processes: [game.identity])
        let provider = NativeProvider(nil, order: n.order)
        let later = n.manager(provider: provider)
        let startup = await later.reattachStartup()
        #expect(startup.sessions["zzz"]?.nativeProxy?.phase == .placed)
        #expect(provider.swept["starrail"] == [n.configuration.sessionDirectory])
        #expect(provider.swept["zzz"] == nil)
        #expect(try n.system32Listing()["d3d11.dll"] == "native proxy d3d11")
        try await n.base.end(later)
        await later.waitForSupervision(game: "zzz")
        #expect(provider.finished == [n.configuration])
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
    }
}

// MARK: Native diagnostic log harvesting

/// Publishing into the log directory always fails; everything else is real.
private struct PublishFailingFileOps: FileOps {
    private let base = SystemFileOps()
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(descriptor, bytes: bytes) }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer, at offset: Int64) throws -> Int {
        try base.write(descriptor, bytes: bytes, at: offset)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try base.synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        throw LauncherError.io("injected publish failure")
    }
    func swap(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32) throws {
        try base.swap(from: source, in: sourceDirectory, to: destination, in: destinationDirectory)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try base.unlink(name, in: directory, isDirectory: isDirectory)
    }
}

private extension NativeFixture {
    func writeRuntimeLog(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: system32.appendingPathComponent(name)) }
    var logsDirectory: URL { base.paths.logs }
    /// The one session log of the launch, and its stem.
    func sessionLog() throws -> (url: URL, stem: String) {
        let logs = try FileManager.default.contentsOfDirectory(atPath: logsDirectory.path).filter { LaunchLogFiles.parseName($0)?.game == "zzz" }
        let name = try #require(logs.first)
        #expect(logs.count == 1)
        return (logsDirectory.appendingPathComponent(name), String(name.dropLast(4)))
    }
    func exports() throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: logsDirectory.path)
        where name.hasSuffix(".d3d11_log.txt") || name.hasSuffix(".ShaderUsage.txt") {
            result[name] = String(decoding: try Data(contentsOf: logsDirectory.appendingPathComponent(name)), as: UTF8.self)
        }
        return result
    }
    func sessionLogText(_ manager: LaunchManager) async throws -> String {
        await manager.flushLogs()
        return String(decoding: try Data(contentsOf: try sessionLog().url), as: UTF8.self)
    }
}

@Suite(.timeLimit(.minutes(1))) struct NativeProxyLogHarvestTests {
    private func run(_ n: NativeFixture, harvester: NativeProxyLogHarvester = NativeProxyLogHarvester(),
        arrange: () throws -> Void) async throws -> (LaunchManager, ManagerEvents) {
        let manager = n.manager(provider: NativeProvider(n.configuration, order: n.order), harvester: harvester)
        let events = ManagerEvents(), consumer = await n.launch(manager, events: events)
        await events.waitForRunning()
        try arrange()
        try await n.base.end(manager); await consumer.value
        await manager.waitForSupervision(game: "zzz")
        return (manager, events)
    }

    @Test func normalEndKeepsTheLogsAfterTheNativeFilesAreRemoved() async throws {
        let n = try await NativeFixture()
        let (manager, events) = try await run(n) {
            try n.writeRuntimeLog("d3d11_log.txt", "loader log\n")
            try n.writeRuntimeLog("ShaderUsage.txt", "usage\n")
        }
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
        let stem = try n.sessionLog().stem
        #expect(try n.exports() == [stem + ".d3d11_log.txt": "loader log\n", stem + ".ShaderUsage.txt": "usage\n"])
        let text = try await n.sessionLogText(manager)
        #expect(text.contains("native diagnostics: d3d11_log.txt exported as \(stem).d3d11_log.txt bytes=11"))
        #expect(text.contains("native diagnostics: ShaderUsage.txt exported as \(stem).ShaderUsage.txt bytes=6"))
        #expect(await events.values.contains { if case .restored(.clean) = $0 { true } else { false } })
    }

    @Test func missingLogsAreBenign() async throws {
        let n = try await NativeFixture()
        let (manager, events) = try await run(n) {}
        #expect(try n.system32Listing() == n.baseline)
        #expect(try n.exports().isEmpty)
        let text = try await n.sessionLogText(manager)
        #expect(text.contains("native diagnostics: d3d11_log.txt not present"))
        #expect(await events.values.contains { if case .restored(.clean) = $0 { true } else { false } })
    }

    @Test func symlinkAndHardlinkLogsAreNeitherFollowedNorExported() async throws {
        let n = try await NativeFixture()
        let outside = n.base.temp.url.appendingPathComponent("outside-secret.txt")
        try Data("secret".utf8).write(to: outside)
        let (manager, _) = try await run(n) {
            try FileManager.default.createSymbolicLink(at: n.system32.appendingPathComponent("d3d11_log.txt"), withDestinationURL: outside)
            try FileManager.default.linkItem(at: outside, to: n.system32.appendingPathComponent("ShaderUsage.txt"))
        }
        #expect(try n.exports().isEmpty)
        #expect(try Data(contentsOf: outside) == Data("secret".utf8))
        // Not ours to remove either: restore retains them for recovery.
        let listing = try n.system32Listing()
        #expect(listing["d3d11_log.txt"] == "link:" + outside.path)
        #expect(listing["ShaderUsage.txt"] == "secret")
        let text = try await n.sessionLogText(manager)
        #expect(text.contains("native diagnostics: d3d11_log.txt not exported: not a regular single-link file"))
        #expect(text.contains("native diagnostics: ShaderUsage.txt not exported: not a regular single-link file"))
        #expect(try await n.journal()?.state == .recoveryPending)
    }

    @Test func oversizedLogIsSkippedAndStillCleanedUp() async throws {
        let n = try await NativeFixture()
        let (manager, events) = try await run(n) {
            let url = n.system32.appendingPathComponent("d3d11_log.txt")
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(NativeProxyLogHarvester.maximumBytes + 1))
            try handle.close()
            try n.writeRuntimeLog("ShaderUsage.txt", "small\n")
        }
        let stem = try n.sessionLog().stem
        #expect(try n.exports() == [stem + ".ShaderUsage.txt": "small\n"])
        #expect(try n.system32Listing() == n.baseline)
        let text = try await n.sessionLogText(manager)
        #expect(text.contains("native diagnostics: d3d11_log.txt not exported: larger than"))
        #expect(await events.values.contains { if case .restored(.clean) = $0 { true } else { false } })
    }

    @Test func harvestFailureNeverPreventsRestoration() async throws {
        let n = try await NativeFixture()
        let (manager, events) = try await run(n, harvester: NativeProxyLogHarvester(fileOps: PublishFailingFileOps())) {
            try n.writeRuntimeLog("d3d11_log.txt", "loader log\n")
        }
        #expect(try n.exports().isEmpty)
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
        let text = try await n.sessionLogText(manager)
        #expect(text.contains("native diagnostics: d3d11_log.txt not exported: copy failed"))
        #expect(await events.values.contains { if case .restored(.clean) = $0 { true } else { false } })
    }

    @Test func reattachRecoveryHarvestsBeforeRestoring() async throws {
        let n = try await NativeFixture()
        var crashed = try await n.crashedSession(processes: [ProcessIdentity(pid: 45678, startTime: 400)])
        let paths = n.base.paths
        let log = try await BlockingIO.run {
            try SessionLog.create(paths: paths, game: "zzz", header: ["recipe": "zzz"])
        }
        crashed.sessionLogURL = log.url
        let withLog = crashed
        try await BlockingIO.run { try LaunchJournal(paths: paths).write(withLog) }
        try n.writeRuntimeLog("d3d11_log.txt", "from a crashed run\n")
        let later = n.manager(provider: nil, preparation: n.base.preparation, harvester: NativeProxyLogHarvester())
        _ = await later.reattachStartup()
        let stem = String(log.url.lastPathComponent.dropLast(4))
        #expect(try n.exports() == [stem + ".d3d11_log.txt": "from a crashed run\n"])
        #expect(try n.system32Listing() == n.baseline)
        #expect(try await n.journal() == nil)
    }

    @Test func disabledSessionLogsExportNothingButStillRestore() async throws {
        let n = try await NativeFixture()
        try await BlockingIO.run {
            try GlobalLaunchSettingsStore(paths: n.base.paths).save(GlobalLaunchSettings(sessionLogsEnabled: false))
        }
        let (_, events) = try await run(n) { try n.writeRuntimeLog("d3d11_log.txt", "x\n") }
        #expect(try n.exports().isEmpty)
        #expect(try n.system32Listing() == n.baseline)
        #expect(await events.values.contains { if case .restored(.clean) = $0 { true } else { false } })
    }

    @Test func nonNativeStarRailLaunchNeverTouchesOrExportsSystem32Logs() async throws {
        let f = try await ManagerFixture.make()
        let foreign = f.prefix.appendingPathComponent("drive_c/windows/system32/d3d11_log.txt")
        try Data("foreign".utf8).write(to: foreign)
        let manager = f.manager()
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        try await f.end(manager); await consumer.value
        await manager.waitForSupervision(game: "starrail")
        await manager.flushLogs()
        #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: f.paths.logs.path)
        #expect(!names.contains { $0.hasSuffix(".d3d11_log.txt") || $0.hasSuffix(".ShaderUsage.txt") })
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }
}
