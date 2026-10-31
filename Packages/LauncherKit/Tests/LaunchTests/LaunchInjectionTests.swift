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
        var configuration: LaunchInjectionConfiguration?
        var error: LauncherError?
        var onPrepare: (@Sendable () throws -> Void)?
    }
    private let state = Mutex(State())
    init(configuration: LaunchInjectionConfiguration? = nil) {
        state.withLock { $0.configuration = configuration }
    }
    var calls: [Call] { state.withLock { $0.calls } }
    func fail(_ error: LauncherError = .io("injected injection preparation failure")) { state.withLock { $0.error = error } }
    func onPrepare(_ action: @escaping @Sendable () throws -> Void) { state.withLock { $0.onPrepare = action } }
    func setConfiguration(_ configuration: LaunchInjectionConfiguration?) {
        state.withLock { $0.configuration = configuration }
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

        try await f.end(manager); await consumer.value
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

    @Test func injectionSupportsOnlyGlobalStarRailOnTheProvenBundle() async throws {
        let f = try await ManagerFixture.make()
        let selection = try makeAllowedRuntime(f)
        let settings = LaunchSettings.defaults(for: "starrail")
        #expect(LaunchInjection.supports(game: try #require(GameDefinition.find("starrail")), bundle: selection.bundle, settings: settings))
        #expect(!LaunchInjection.supports(game: try #require(GameDefinition.find("starrail-cn")), bundle: selection.bundle, settings: settings))
        #expect(!LaunchInjection.supports(game: try #require(GameDefinition.find("zzz")), bundle: selection.bundle, settings: settings))
        var dxmt = settings; dxmt.backend = .dxmt
        #expect(!LaunchInjection.supports(game: try #require(GameDefinition.find("starrail")), bundle: selection.bundle, settings: dxmt))
        let other = InstalledRuntimeBundle(id: try SafeIdentifier("bundle-a"), root: selection.bundle.root,
            wineBinary: selection.bundle.wineBinary, digest: selection.bundle.digest, source: .download)
        #expect(!LaunchInjection.supports(game: try #require(GameDefinition.find("starrail")), bundle: other, settings: settings))
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
