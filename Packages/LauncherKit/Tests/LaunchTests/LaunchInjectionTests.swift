// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import GameLibrary
import RuntimeManager
import TestSupport
@testable import Launch

private let provenBundleID = "d3dmetal-wine11.20-gptk4.0b3"

private final class InjectionSpawner: ProcessSpawner, Sendable {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let currentDirectory: URL
    }
    private struct State {
        var calls: [Call] = []
        var failure: LauncherError?
        var afterSpawn: (@Sendable () throws -> Void)?
    }
    private let state = Mutex(State())
    let identity = ProcessIdentity(pid: 12345, startTime: 100)
    var calls: [Call] { state.withLock { $0.calls } }
    func fail(_ error: LauncherError = .io("injected spawn failure")) { state.withLock { $0.failure = error } }
    func afterSpawn(_ action: @escaping @Sendable () throws -> Void) { state.withLock { $0.afterSpawn = action } }

    func spawn(_ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL, output: ProcessOutput) throws -> ProcessIdentity {
        let action = try state.withLock { state -> (@Sendable () throws -> Void)? in
            state.calls.append(Call(executable: executable, arguments: arguments, environment: environment,
                currentDirectory: currentDirectory))
            if let failure = state.failure { throw failure }
            return state.afterSpawn
        }
        try action?()
        return identity
    }
}

private final class RecordingInjectionProvider: LaunchInjectionPreparing, Sendable {
    struct Call: Equatable, Sendable {
        let gameID: String
        let runtimeBundleID: String
        let backendD3D11: URL
    }
    private struct State {
        var calls: [Call] = []
        var finished: [LaunchInjectionConfiguration] = []
        var configuration: LaunchInjectionConfiguration?
        var error: LauncherError?
        var onPrepare: (@Sendable () throws -> Void)?
        var finishFails = false
        var onFinish: (@Sendable () -> Void)?
        var discarded: [LaunchInjectionConfiguration] = []
        var swept: [String: [URL]] = [:]
        var applied: [LaunchInjectionConfiguration] = []
        var applyGate: (started: InjectionLatch, release: InjectionLatch)?
        var order: [String] = []
    }
    private let state = Mutex(State())
    init(configuration: LaunchInjectionConfiguration? = nil) {
        state.withLock { $0.configuration = configuration }
    }
    var calls: [Call] { state.withLock { $0.calls } }
    var finished: [LaunchInjectionConfiguration] { state.withLock { $0.finished } }
    func fail(_ error: LauncherError = .io("injected injection preparation failure")) { state.withLock { $0.error = error } }
    func onPrepare(_ action: @escaping @Sendable () throws -> Void) { state.withLock { $0.onPrepare = action } }
    func setConfiguration(_ configuration: LaunchInjectionConfiguration?) {
        state.withLock { $0.configuration = configuration }
    }
    func validateEligibility(game: GameDefinition, settings: LaunchSettings) async throws {
        if game.id == "zzz", settings.directX12,
            state.withLock({ $0.configuration != nil }) {
            throw LauncherError.io("Direct3D 11 required")
        }
    }
    func prepare(gameID: String, runtimeBundleID: String, backendD3D11: URL) async throws -> LaunchInjectionConfiguration? {
        let (error, action, configuration) = state.withLock { state in
            state.calls.append(Call(gameID: gameID, runtimeBundleID: runtimeBundleID, backendD3D11: backendD3D11))
            return (state.error, state.onPrepare, state.configuration)
        }
        if let error { throw error }
        try action?()
        return configuration
    }
    func failFinish() { state.withLock { $0.finishFails = true } }
    func finish(configuration: LaunchInjectionConfiguration) async throws {
        let (fails, action) = state.withLock { state in
            state.finished.append(configuration)
            state.order.append("finish")
            let action = state.onFinish
            state.onFinish = nil
            return (state.finishFails, action)
        }
        action?()
        if fails { throw LauncherError.io("injected settings save failure") }
    }
    func allowFinish() { state.withLock { $0.finishFails = false } }
    func onNextFinish(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.onFinish = action } }
    var discarded: [LaunchInjectionConfiguration] { state.withLock { $0.discarded } }
    var swept: [String: [URL]] { state.withLock { $0.swept } }
    var applied: [LaunchInjectionConfiguration] { state.withLock { $0.applied } }
    var order: [String] { state.withLock { $0.order } }
    func blockApply(started: InjectionLatch, release: InjectionLatch) {
        state.withLock { $0.applyGate = (started, release) }
    }
    func discard(configuration: LaunchInjectionConfiguration) async {
        state.withLock { $0.discarded.append(configuration) }
    }
    func sweepSessions(gameID: String, retaining: [URL]) async {
        state.withLock { $0.swept[gameID] = retaining }
    }
    func applyLive(configuration: LaunchInjectionConfiguration) async throws {
        let gate = state.withLock { state in
            state.applied.append(configuration)
            state.order.append("apply-start")
            return state.applyGate
        }
        if let gate {
            gate.started.open()
            await gate.release.wait()
        }
        state.withLock { $0.order.append("apply-end") }
    }
}

final class InjectionLatch: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private final class InjectionOrder: Sendable {
    private let values = Mutex<[String]>([])
    func append(_ value: String) { values.withLock { $0.append(value) } }
    var all: [String] { values.withLock { $0 } }
}

private func addRootDriveMapping(_ f: ManagerFixture) throws {
    let dosdevices = f.prefix.appendingPathComponent("dosdevices", isDirectory: true)
    try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
    let link = dosdevices.appendingPathComponent("z:")
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil {
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/")
    }
}

private func makeAllowedRuntime(_ f: ManagerFixture, name: String = "verified", backendFile: Bool = true) throws -> LaunchRuntimeSelection {
    let root = f.paths.runtimes.appendingPathComponent("bundles/\(name)", isDirectory: true)
    let windows = root.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
    try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
    if backendFile { try Data("d3d11".utf8).write(to: windows.appendingPathComponent("d3d11.dll")) }
    let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(provenBundleID), root: root,
        wineBinary: root.appendingPathComponent("bin/wine"), digest: f.bundle.digest, source: .download)
    return LaunchRuntimeSelection(bundle: bundle, componentIDs: f.runtime.selected.componentIDs,
        componentRoots: f.runtime.selected.componentRoots,
        compatibilityComponentIDs: f.runtime.selected.compatibilityComponentIDs)
}

private func makeInjectionSnapshot(_ f: ManagerFixture, name: String = UUID().uuidString,
    files: [String] = ["hook-runner.exe", "3dmloader.dll", "d3d11.dll"]) throws -> LaunchInjectionConfiguration {
    let session = f.paths.root.appendingPathComponent("XXMI/Sessions/\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    for file in files { try Data("fixture \(file)".utf8).write(to: session.appendingPathComponent(file)) }
    return LaunchInjectionConfiguration(runnerURL: session.appendingPathComponent("hook-runner.exe"),
        injectorURL: session.appendingPathComponent("3dmloader.dll"),
        payloadURL: session.appendingPathComponent("d3d11.dll"), sessionDirectory: session)
}

private func makeZZZInjectionSnapshot(_ f: ManagerFixture) throws -> LaunchInjectionConfiguration {
    let configuration = try makeInjectionSnapshot(f)
    return LaunchInjectionConfiguration(runnerURL: configuration.runnerURL,
        injectorURL: configuration.injectorURL, payloadURL: configuration.payloadURL,
        sessionDirectory: configuration.sessionDirectory, gameID: "zzz",
        targetExecutable: "ZenlessZoneZero.exe")
}

private func makeManager(_ f: ManagerFixture, selection: LaunchRuntimeSelection,
    provider: (any LaunchInjectionPreparing)?, spawner: any ProcessSpawner,
    displayProbe: any DisplayProbe = FixedDisplayProbe()) -> LaunchManager {
    LaunchManager(paths: f.paths, runtimes: ManagerRuntimeProvider(selected: selection), prefixes: f.prefixes,
        preparation: f.preparation, spawner: spawner, inspector: f.inspector, runner: f.runner, clock: f.clock,
        log: nil, displayProbe: displayProbe,
        proxyFactory: { [proxy = f.proxy] _, log in proxy.start(log: log); return proxy },
        baseEnvironment: [:], journalFileOps: f.journalOps, hideHooks: .none,
        beforeJournalRead: {}, beforeRecoveryRead: {}, recipeOverrides: [:],
        sessionProvenance: { (ManagerFixture.bootSessionUUID, ManagerFixture.sessionStartTime) },
        beforeSessionLogWrite: {}, injectionPreparation: provider)
}

private func resolvedLaunch(_ f: ManagerFixture, selection: LaunchRuntimeSelection, proxyPort: UInt16) throws -> ResolvedLaunch {
    try LaunchResolver.resolve(recipe: try #require(Recipes.recipe(for: "starrail")), settings: .defaults(for: "starrail"),
        installRoot: f.installRoot, prefix: f.prefix, wineBinary: selection.bundle.wineBinary, proxyPort: proxyPort,
        componentRoots: selection.componentRoots, baseEnvironment: [:], runtimeBundleID: selection.bundle.id.rawValue)
}

@Suite(.timeLimit(.minutes(1))) struct LaunchInjectionTests {
    @Test func enabledInjectionWrapsResolvedCommandAfterPreparation() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        let order = InjectionOrder()
        provider.onPrepare { order.append("prepare") }
        let spawner = InjectionSpawner()
        spawner.afterSpawn { order.append("spawn") }
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()

        let call = try #require(spawner.calls.first)
        let original = try resolvedLaunch(f, selection: selection, proxyPort: f.proxy.port)
        #expect(call.executable == selection.bundle.wineBinary)
        #expect(call.currentDirectory == f.installRoot)
        #expect(call.environment == original.environment)
        #expect(call.environment["WINEPREFIX"] == f.prefix.path)
        #expect(call.arguments == [WinePath.windowsPath(for: configuration.runnerURL), "--loader",
            WinePath.windowsPath(for: configuration.injectorURL), "--payload",
            WinePath.windowsPath(for: configuration.payloadURL), "--"] + original.arguments)
        #expect(call.arguments.suffix(original.arguments.count) == original.arguments[...])
        let request = try #require(provider.calls.first)
        #expect(request.gameID == "starrail")
        #expect(request.runtimeBundleID == provenBundleID)
        #expect(request.backendD3D11 == selection.bundle.root.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"))
        #expect(order.all == ["prepare", "spawn"])
        let journal = try await f.journal()
        #expect(journal?.injection == configuration)
        #expect(provider.finished.isEmpty)

        try await f.end(manager); await consumer.value
        #expect(provider.finished == [configuration])
    }

    @Test func settingsHarvestFailureRemainsRetryable() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        provider.failFinish()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: InjectionSpawner())
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        try await f.end(manager)
        await manager.waitForSupervision(game: "starrail")
        await consumer.value
        let pending = try #require(try await f.journal())
        #expect(pending.endLogged != true)
        #expect(pending.state == .recoveryPending)
        #expect(provider.finished == [configuration])
        provider.allowFinish()
        try await manager.recoverIfNeeded(game: "starrail")
        #expect(provider.finished.count == 2)
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
    }

    @Test func nilConfigurationPreservesOriginalLaunch() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let provider = RecordingInjectionProvider(configuration: nil)
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()

        let call = try #require(spawner.calls.first)
        let original = try resolvedLaunch(f, selection: selection, proxyPort: f.proxy.port)
        #expect(call.executable == original.executable)
        #expect(call.arguments == original.arguments)
        #expect(call.environment == original.environment)
        #expect(call.currentDirectory == original.currentDirectory)
        #expect(provider.calls.count == 1)
        let journal = try await f.journal()
        #expect(journal?.injection == nil)

        try await f.end(manager); await consumer.value
    }

    @Test func enabledInjectionRejectsUnverifiedRuntimeBundleBeforeSpawn() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: f.runtime.selected, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.wait { if case .failed = $0 { true } else { false } }
        await consumer.value

        #expect(spawner.calls.isEmpty)
        #expect(provider.calls.count == 1)
        #expect(f.proxy.starts == 0)
        #expect(try await f.journal() == nil)
    }

    @Test func enabledInjectionRejectsNonD3DMetalBackendBeforeSpawn() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        try await BlockingIO.run {
            var settings = LaunchSettings.defaults(for: "starrail"); settings.backend = .dxmt
            try LaunchSettingsStore(paths: f.paths).save(settings, for: "starrail")
        }
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.wait { if case .failed = $0 { true } else { false } }
        await consumer.value

        #expect(spawner.calls.isEmpty)
        #expect(provider.calls.count == 1)
        #expect(f.proxy.starts == 0)
        #expect(try await f.journal() == nil)
    }

    @Test func injectionSupportsOnlyGlobalStarRailAndZZZOnTheProvenBundle() async throws {
        let f = try await ManagerFixture.make()
        let selection = try makeAllowedRuntime(f)
        let settings = LaunchSettings.defaults(for: "starrail")
        let starRail = try #require(GameDefinition.find("starrail"))
        let zzz = try #require(GameDefinition.find("zzz"))
        #expect(LaunchInjection.supports(game: starRail, bundle: selection.bundle, settings: settings))
        #expect(!LaunchInjection.supports(game: try #require(GameDefinition.find("starrail-cn")), bundle: selection.bundle, settings: settings))
        #expect(!LaunchInjection.supports(game: try #require(GameDefinition.find("zzz-cn")), bundle: selection.bundle, settings: settings))
        var zzzSettings = LaunchSettings.defaults(for: "zzz")
        #expect(zzzSettings.directX12)
        #expect(!LaunchInjection.supports(game: zzz, bundle: selection.bundle, settings: zzzSettings))
        zzzSettings.directX12 = false
        #expect(LaunchInjection.supports(game: zzz, bundle: selection.bundle, settings: zzzSettings))
        var dxmt = settings; dxmt.backend = .dxmt
        #expect(!LaunchInjection.supports(game: starRail, bundle: selection.bundle, settings: dxmt))
        let other = InstalledRuntimeBundle(id: try SafeIdentifier("bundle-a"), root: selection.bundle.root,
            wineBinary: selection.bundle.wineBinary, digest: selection.bundle.digest, source: .download)
        #expect(!LaunchInjection.supports(game: starRail, bundle: other, settings: settings))
    }

    @Test func providerIsNotConsultedBeforePrefixPreparationSucceeds() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        f.preparation.fail()
        let provider = RecordingInjectionProvider(configuration: try makeInjectionSnapshot(f))
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.wait { if case .failed = $0 { true } else { false } }
        await consumer.value

        #expect(provider.calls.isEmpty)
        #expect(spawner.calls.isEmpty)
        #expect(f.proxy.starts == 0)
        #expect(try await f.journal() == nil)
    }

    @Test func providerFailureFailsClosedBeforeSpawn() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let provider = RecordingInjectionProvider(configuration: nil)
        provider.fail()
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.wait { if case .failed = $0 { true } else { false } }
        await consumer.value

        #expect(provider.calls.count == 1)
        #expect(spawner.calls.isEmpty)
        #expect(f.proxy.starts == 0)
        #expect(try await f.journal() == nil)
    }

    @Test func invalidInjectionSnapshotFailsClosedBeforeSpawn() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let valid = try makeInjectionSnapshot(f)
        let other = try makeInjectionSnapshot(f)
        let invalid = LaunchInjectionConfiguration(runnerURL: other.runnerURL, injectorURL: valid.injectorURL,
            payloadURL: valid.payloadURL, sessionDirectory: valid.sessionDirectory)
        let provider = RecordingInjectionProvider(configuration: invalid)
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.wait { if case .failed = $0 { true } else { false } }
        await consumer.value

        #expect(spawner.calls.isEmpty)
        #expect(f.proxy.starts == 0)
        #expect(try await f.journal() == nil)
    }

    @Test func injectionSnapshotValidationRejectsBadPaths() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let valid = try makeInjectionSnapshot(f)
        let other = try makeInjectionSnapshot(f)
        let outside = f.paths.root.appendingPathComponent("XXMI/NotSessions/session", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        for file in ["hook-runner.exe", "3dmloader.dll", "d3d11.dll"] {
            try Data("outside".utf8).write(to: outside.appendingPathComponent(file))
        }
        let sessionLink = f.paths.root.appendingPathComponent("XXMI/Sessions/linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: sessionLink.path, withDestinationPath: valid.sessionDirectory.path)
        let fileLink = valid.sessionDirectory.appendingPathComponent("runner-link.exe")
        try FileManager.default.createSymbolicLink(atPath: fileLink.path, withDestinationPath: valid.runnerURL.path)
        let directoryPayload = valid.sessionDirectory.appendingPathComponent("payload-dir.dll", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryPayload, withIntermediateDirectories: true)

        let invalid = [
            LaunchInjectionConfiguration(runnerURL: valid.runnerURL, injectorURL: valid.injectorURL,
                payloadURL: valid.payloadURL, sessionDirectory: outside),
            LaunchInjectionConfiguration(runnerURL: other.runnerURL, injectorURL: valid.injectorURL,
                payloadURL: valid.payloadURL, sessionDirectory: valid.sessionDirectory),
            LaunchInjectionConfiguration(runnerURL: fileLink, injectorURL: valid.injectorURL,
                payloadURL: valid.payloadURL, sessionDirectory: valid.sessionDirectory),
            LaunchInjectionConfiguration(runnerURL: valid.runnerURL, injectorURL: valid.injectorURL,
                payloadURL: valid.payloadURL, sessionDirectory: sessionLink),
            LaunchInjectionConfiguration(runnerURL: valid.runnerURL, injectorURL: valid.injectorURL,
                payloadURL: valid.sessionDirectory.appendingPathComponent("missing.dll"), sessionDirectory: valid.sessionDirectory),
            LaunchInjectionConfiguration(runnerURL: valid.runnerURL, injectorURL: valid.injectorURL,
                payloadURL: directoryPayload, sessionDirectory: valid.sessionDirectory),
            LaunchInjectionConfiguration(runnerURL: valid.sessionDirectory.appendingPathComponent("../outside.exe"),
                injectorURL: valid.injectorURL, payloadURL: valid.payloadURL, sessionDirectory: valid.sessionDirectory),
        ]
        try await BlockingIO.run {
            for configuration in invalid {
                #expect(throws: LauncherError.self) {
                    try LaunchInjection.validate(configuration, paths: f.paths, prefix: f.prefix, bundle: selection.bundle)
                }
            }
        }
        #expect(throws: Never.self) {
            try LaunchInjection.validate(valid, paths: f.paths, prefix: f.prefix, bundle: selection.bundle)
        }
    }

    @Test func injectionSnapshotValidationRejectsMissingBackendOrRootMapping() async throws {
        let f = try await ManagerFixture.make()
        let valid = try makeInjectionSnapshot(f)
        let withoutBackend = try makeAllowedRuntime(f, name: "missing-backend", backendFile: false)
        try addRootDriveMapping(f)
        _ = try await BlockingIO.run {
            #expect(throws: LauncherError.self) {
                try LaunchInjection.validate(valid, paths: f.paths, prefix: f.prefix, bundle: withoutBackend.bundle)
            }
        }

        let f2 = try await ManagerFixture.make()
        let valid2 = try makeInjectionSnapshot(f2)
        let selection = try makeAllowedRuntime(f2)
        _ = try await BlockingIO.run {
            #expect(throws: LauncherError.self) {
                try LaunchInjection.validate(valid2, paths: f2.paths, prefix: f2.prefix, bundle: selection.bundle)
            }
        }
    }

    @Test func injectionSnapshotSurvivesSessionJournalRoundTripAndLegacyDecode() async throws {
        let f = try await ManagerFixture.make()
        let configuration = try makeInjectionSnapshot(f)
        let identity = try await BlockingIO.run { try ContainedFileSystem(root: f.installRoot).rootIdentity() }
        let snapshot = LaunchSession(sessionID: UUID(), game: "starrail", installRoot: f.installRoot,
            installIdentity: identity, prefix: f.prefix, bundleID: f.bundle.id.rawValue, runtimeDigest: f.bundle.digest,
            wineBinary: f.bundle.wineBinary, wineserver: f.bundle.wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver"),
            componentIDs: f.runtime.selected.componentIDs, recipeVersion: 1, settings: .defaults(for: "starrail"),
            injection: configuration)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(LaunchSession.self, from: encoded).injection == configuration)

        let legacy = try JSONEncoder().encode(LaunchSession(sessionID: snapshot.sessionID, game: snapshot.game,
            installRoot: f.installRoot, installIdentity: identity, prefix: f.prefix, bundleID: f.bundle.id.rawValue,
            runtimeDigest: f.bundle.digest, wineBinary: f.bundle.wineBinary,
            wineserver: f.bundle.wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver"),
            componentIDs: f.runtime.selected.componentIDs, recipeVersion: 1, settings: .defaults(for: "starrail")))
        #expect(!String(decoding: legacy, as: UTF8.self).contains("\"injection\""))
        #expect(try JSONDecoder().decode(LaunchSession.self, from: legacy).injection == nil)
    }

    @Test func enabledInjectionRejectsUnsupportedGameBeforeSpawn() async throws {
        let f = try await ManagerFixture.make()
        let selection = try makeAllowedRuntime(f)
        let provider = RecordingInjectionProvider(configuration: try makeInjectionSnapshot(f))
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents()
        let game = try #require(GameDefinition.find("starrail-cn"))
        let stream = await manager.launch(game: game, installRoot: f.installRoot, gameBuild: "4.6.0")
        let consumer = Task { for await event in stream { await events.append(event) } }
        await events.wait { if case .failed = $0 { true } else { false } }
        await consumer.value

        #expect(provider.calls.count == 1)
        #expect(spawner.calls.isEmpty)
        #expect(f.proxy.starts == 0)
    }

    @Test func zzzInjectionUsesItsExplicitTargetAndDirect3D11() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        try Data("game".utf8).write(to: f.installRoot.appendingPathComponent("ZenlessZoneZero.exe"))
        let settings = LaunchSettings(backend: .d3dmetal, retina: false, frameLimit: nil,
            directX12: false, compatibilityPatches: false)
        try await BlockingIO.run { try LaunchSettingsStore(paths: f.paths).save(settings, for: "zzz") }
        let configuration = try makeZZZInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        let spawner = InjectionSpawner()
        spawner.afterSpawn {
            f.inspector.update {
                $0.processes = [InspectedProcess(identity: spawner.identity,
                    executablePath: "/wine/ZenlessZoneZero.exe", arguments: [])]
                $0.alive = [spawner.identity]
            }
        }
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents()
        let game = try #require(GameDefinition.find("zzz"))
        let stream = await manager.launch(game: game, installRoot: f.installRoot, gameBuild: "3.3.0")
        let consumer = Task { for await event in stream { await events.append(event) } }
        await events.waitForRunning()

        let call = try #require(spawner.calls.first)
        let original = try LaunchResolver.resolve(recipe: try #require(Recipes.recipe(for: "zzz")),
            settings: settings, installRoot: f.installRoot, prefix: f.prefix,
            wineBinary: selection.bundle.wineBinary, proxyPort: f.proxy.port,
            componentRoots: selection.componentRoots, baseEnvironment: [:],
            runtimeBundleID: selection.bundle.id.rawValue)
        #expect(call.arguments == [WinePath.windowsPath(for: configuration.runnerURL), "--loader",
            WinePath.windowsPath(for: configuration.injectorURL), "--payload",
            WinePath.windowsPath(for: configuration.payloadURL), "--target-exe",
            "ZenlessZoneZero.exe", "--"] + original.arguments)
        #expect(call.arguments.suffix(original.arguments.count) == original.arguments[...])
        let journal = try await BlockingIO.run { try LaunchJournal(paths: f.paths).read(game: "zzz") }
        #expect(journal?.injection?.gameID == "zzz")
        #expect(journal?.injection?.resolvedTargetExecutable == "ZenlessZoneZero.exe")

        try await f.end(manager); await consumer.value
    }

    @Test func zzzDirectX12InjectionFailsClosedBeforeSnapshotAndPreparation() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        try Data("game".utf8).write(to: f.installRoot.appendingPathComponent("ZenlessZoneZero.exe"))
        let settings = LaunchSettings(backend: .d3dmetal, retina: false, frameLimit: nil,
            directX12: true, compatibilityPatches: false)
        try await BlockingIO.run { try LaunchSettingsStore(paths: f.paths).save(settings, for: "zzz") }
        let provider = RecordingInjectionProvider(configuration: try makeZZZInjectionSnapshot(f))
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents()
        let game = try #require(GameDefinition.find("zzz"))
        let stream = await manager.launch(game: game, installRoot: f.installRoot, gameBuild: "3.3.0")
        let consumer = Task { for await event in stream { await events.append(event) } }
        await events.wait { if case .failed = $0 { true } else { false } }
        await consumer.value

        let stages = await events.values.compactMap { event -> LaunchStage? in
            if case .stage(let stage) = event { return stage }
            return nil
        }
        #expect(!stages.contains(.snapshot))
        #expect(!stages.contains(.prepare))
        #expect(provider.calls.isEmpty)
        #expect(try await BlockingIO.run { try LaunchSettingsStore(paths: f.paths).load("zzz") } == settings)
        #expect(spawner.calls.isEmpty)
        #expect(f.proxy.starts == 0)
        #expect(try await BlockingIO.run {
            try LaunchJournal(paths: f.paths).read(game: "zzz")
        } == nil)
    }

    @Test func failureAfterTheHelperStartsKeepsSupervisionUntilVerifiedEnd() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        let spawner = InjectionSpawner()
        spawner.afterSpawn { f.journalOps.arm() }
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()

        let pending = try #require(try await f.journal())
        // The watcher confirmed the guest and retained the session; the failed
        // post-spawn snapshot write must not restore or release ownership.
        #expect(pending.state == .running)
        #expect(pending.injection == configuration)
        #expect(pending.processes.contains(spawner.identity))
        #expect(f.proxy.stops == 0)
        try await f.assertHidden()

        try await f.end(manager)
        await manager.waitForSupervision(game: "starrail")
        await consumer.value
        #expect(f.proxy.stops == 1)
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
    }
}

@Suite(.timeLimit(.minutes(1))) struct LaunchInjectionLifecycleTests {
    @Test func snapshotRejectedAfterPreparationIsDiscarded() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        // The fixture's default bundle is not the verified runtime.
        let manager = makeManager(f, selection: f.runtime.selected, provider: provider, spawner: InjectionSpawner())
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.wait { if case .failed = $0 { true } else { false } }
        await consumer.value
        #expect(provider.discarded == [configuration])
        #expect(provider.finished.isEmpty)
    }

    @Test func snapshotIsDiscardedWhenItsJournalWriteFails() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        // The next journal write is the one that would record the snapshot.
        provider.onPrepare { f.journalOps.arm() }
        let spawner = InjectionSpawner()
        let manager = makeManager(f, selection: selection, provider: provider, spawner: spawner)
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.wait { if case .failed = $0 { true } else { false } }
        await manager.waitForSupervision(game: "starrail")
        await consumer.value
        #expect(spawner.calls.isEmpty)
        #expect(provider.discarded == [configuration])
    }

    @Test func finishRepeatsSafelyWhenTheEndCheckpointFails() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        let manager = makeManager(f, selection: selection, provider: provider, spawner: InjectionSpawner())
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        // finish succeeds, then the endLogged journal write fails.
        provider.onNextFinish { f.journalOps.arm() }
        try await f.end(manager)
        await manager.waitForSupervision(game: "starrail")
        await consumer.value
        let pending = try #require(try await f.journal())
        #expect(pending.endLogged != true)
        #expect(provider.finished == [configuration])
        try await manager.recoverIfNeeded(game: "starrail")
        #expect(provider.finished == [configuration, configuration])
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
    }

    @Test func liveApplyRequiresTheRunningJournaledSession() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        let manager = makeManager(f, selection: selection, provider: provider, spawner: InjectionSpawner())
        await #expect(throws: LauncherError.self) { try await manager.applyLiveInjectionUpdate(game: "starrail") }
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        try await manager.applyLiveInjectionUpdate(game: "starrail")
        #expect(provider.applied == [configuration])
        await #expect(throws: LauncherError.self) { try await manager.applyLiveInjectionUpdate(game: "zzz") }
        try await f.end(manager)
        await manager.waitForSupervision(game: "starrail")
        await consumer.value
        await #expect(throws: LauncherError.self) { try await manager.applyLiveInjectionUpdate(game: "starrail") }
        #expect(provider.applied == [configuration])
        #expect(provider.finished == [configuration])
    }

    @Test func liveApplyWithoutInjectionIsRejected() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let provider = RecordingInjectionProvider(configuration: nil)
        let manager = makeManager(f, selection: selection, provider: provider, spawner: InjectionSpawner())
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        await #expect(throws: LauncherError.self) { try await manager.applyLiveInjectionUpdate(game: "starrail") }
        #expect(provider.applied.isEmpty)
        try await f.end(manager); await consumer.value
    }

    @Test func verifiedEndWaitsForAnInFlightLiveApply() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let configuration = try makeInjectionSnapshot(f)
        let provider = RecordingInjectionProvider(configuration: configuration)
        let started = InjectionLatch(), release = InjectionLatch()
        provider.blockApply(started: started, release: release)
        let manager = makeManager(f, selection: selection, provider: provider, spawner: InjectionSpawner())
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        // A cancelled caller does not abandon publication; end still waits for it.
        let apply = Task { try await manager.applyLiveInjectionUpdate(game: "starrail") }
        await started.wait()
        apply.cancel()
        await #expect(throws: LauncherError.self) { try await manager.applyLiveInjectionUpdate(game: "starrail") }
        try await f.end(manager)
        await events.wait { if case .ended = $0 { true } else { false } }
        #expect(provider.finished.isEmpty)
        release.open()
        try await apply.value
        await manager.waitForSupervision(game: "starrail")
        await consumer.value
        #expect(provider.order == ["apply-start", "apply-end", "finish"])
        #expect(try await f.journal() == nil)
    }

    @Test func startupSweepLocksEachInjectableGameAndRetainsLiveSnapshots() async throws {
        let f = try await ManagerFixture.make()
        try addRootDriveMapping(f)
        let selection = try makeAllowedRuntime(f)
        let provider = RecordingInjectionProvider(configuration: nil)
        let idle = makeManager(f, selection: selection, provider: provider, spawner: InjectionSpawner())
        _ = await idle.reattachStartup()
        #expect(Set(provider.swept.keys) == ["starrail", "zzz"])
        #expect(provider.swept["zzz"] == [])

        // Another instance holding the ZZZ session lock excludes that game.
        do {
            let held = try await BlockingIO.run { try SessionLock.acquire(paths: f.paths, game: "zzz") }
            let provider2 = RecordingInjectionProvider(configuration: nil)
            _ = await makeManager(f, selection: selection, provider: provider2, spawner: InjectionSpawner()).reattachStartup()
            #expect(Set(provider2.swept.keys) == ["starrail"])
            withExtendedLifetime(held) {}
        }

        // A reattached, still-running session is live: its game is skipped and
        // its snapshot is retained for every other game's sweep.
        let configuration = try makeInjectionSnapshot(f)
        var snapshot = try await f.saveSnapshot(state: .running, processes: [f.gameProcess.identity],
            gameExecutable: try SafeRelativePath("StarRail.exe"))
        snapshot.injection = configuration
        let written = snapshot
        try await BlockingIO.run { try LaunchJournal(paths: f.paths).write(written) }
        let provider3 = RecordingInjectionProvider(configuration: nil)
        let reattached = makeManager(f, selection: selection, provider: provider3, spawner: InjectionSpawner())
        let startup = await reattached.reattachStartup()
        #expect(startup.sessions["starrail"] != nil)
        #expect(Set(provider3.swept.keys) == ["zzz"])
        #expect(provider3.swept["zzz"] == [configuration.sessionDirectory])

        // The explicit apply routes to the journal's snapshot after reattach.
        try await reattached.applyLiveInjectionUpdate(game: "starrail")
        #expect(provider3.applied == [configuration])
        try await f.end(reattached)
        await reattached.waitForSupervision(game: "starrail")
        #expect(provider3.finished == [configuration])
    }
}
