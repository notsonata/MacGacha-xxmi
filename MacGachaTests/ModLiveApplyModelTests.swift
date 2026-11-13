// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import GameLibrary
import Launch
import LauncherCore
import ModSupport
import RuntimeManager
@testable import MacGacha

private actor LiveApplyServices: LaunchServices {
    var sessions: [String: LaunchSession] = [:]
    var applied: [String] = []
    var failure: LauncherError?
    func set(_ session: LaunchSession?, for id: String) { sessions[id] = session }
    func fail(_ error: LauncherError?) { failure = error }
    func reattach() async throws -> [String: LaunchSession] { [:] }
    func launch(game: GameDefinition, record: GameRecord) async throws -> AsyncStream<LaunchEvent> {
        AsyncStream { $0.finish() }
    }
    func observation(_ id: String) async throws -> LaunchObservation? { nil }
    func recover(_ id: String) async throws {}
    func session(_ id: String) async -> LaunchSession? { sessions[id] }
    func gameProcessIDs(_ id: String) async -> [Int32] { [] }
    func markReady(_ id: String) async {}
    func notices() async throws -> [RecoveryNotice] { [] }
    func acknowledge(_ id: UUID) async throws {}
    func applyModsToRunningGame(_ id: String) async throws {
        applied.append(id)
        if let failure { throw failure }
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct ModLiveApplyModelTests {
    private func session(_ paths: AppPaths, game: String, injected: Bool) throws -> LaunchSession {
        var session = LaunchSession(sessionID: UUID(), game: game, installRoot: paths.games,
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1), prefix: paths.prefixes,
            bundleID: "test", runtimeDigest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)),
            wineBinary: paths.runtimes.appendingPathComponent("wine"), wineserver: paths.runtimes.appendingPathComponent("wineserver"),
            componentIDs: [], recipeVersion: 1, settings: .defaults(for: game), state: .running)
        if injected {
            let directory = paths.root.appendingPathComponent(
                game == "zzz" ? "XXMI/Sessions/zzz/\(UUID().uuidString)" : "XXMI/Sessions/\(UUID().uuidString)",
                isDirectory: true)
            session.injection = LaunchInjectionConfiguration(runnerURL: directory.appendingPathComponent("hook-runner.exe"),
                injectorURL: directory.appendingPathComponent("3dmloader.dll"),
                payloadURL: directory.appendingPathComponent("payload/d3d11.dll"), sessionDirectory: directory,
                gameID: game, targetExecutable: game == "zzz" ? "ZenlessZoneZero.exe" : "StarRail.exe")
        }
        return session
    }

    private func makeModel(_ services: LiveApplyServices) throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaLiveApply-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(paths: AppPaths(root: root), manifest: try RuntimeManifest(components: []),
            services: PreviewRuntimeServices(), defaults: nil, launchServices: services)
        return (model, root)
    }

    @Test func applyIsOfferedOnlyForARunningInjectedSession() async throws {
        let services = LiveApplyServices()
        let (model, root) = try makeModel(services)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)

        await services.set(try session(paths, game: "starrail", injected: true), for: "starrail")
        await model.refreshModLiveApplyEligibility(gameID: "starrail")
        #expect(!model.canApplyModsToRunningGame(gameID: "starrail"))

        model.launchStates["starrail"] = .running
        await model.refreshModLiveApplyEligibility(gameID: "starrail")
        #expect(model.canApplyModsToRunningGame(gameID: "starrail"))

        await services.set(try session(paths, game: "starrail", injected: false), for: "starrail")
        await model.refreshModLiveApplyEligibility(gameID: "starrail")
        #expect(!model.canApplyModsToRunningGame(gameID: "starrail"))

        // Unsupported editions are never offered, even while running.
        model.launchStates["starrail-cn"] = .ready
        await services.set(try session(paths, game: "starrail-cn", injected: true), for: "starrail-cn")
        await model.refreshModLiveApplyEligibility(gameID: "starrail-cn")
        #expect(!model.canApplyModsToRunningGame(gameID: "starrail-cn"))
        #expect(await services.applied.isEmpty)
    }

    @Test func explicitApplyPromptsForTheInGameReloadOnlyAfterSuccess() async throws {
        let services = LiveApplyServices()
        let (model, root) = try makeModel(services)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        model.launchStates["zzz"] = .ready
        await services.set(try session(paths, game: "zzz", injected: true), for: "zzz")
        await model.refreshModLiveApplyEligibility(gameID: "zzz")

        await services.fail(.io("injected"))
        model.applyModsToRunningGame(gameID: "zzz")
        await model.modSupportTasks["zzz"]?.value
        #expect(!model.showsModLiveApplyPrompt(gameID: "zzz"))
        #expect(model.modSupportError(for: "zzz") != nil)

        await services.fail(nil)
        model.applyModsToRunningGame(gameID: "zzz")
        await model.modSupportTasks["zzz"]?.value
        #expect(await services.applied == ["zzz", "zzz"])
        #expect(model.showsModLiveApplyPrompt(gameID: "zzz"))
        #expect(model.modSupportError(for: "zzz") == nil)

        // Once the game stops running the prompt and action disappear.
        model.launchStates["zzz"] = nil
        await model.refreshModLiveApplyEligibility(gameID: "zzz")
        #expect(!model.showsModLiveApplyPrompt(gameID: "zzz"))
        model.applyModsToRunningGame(gameID: "zzz")
        #expect(model.modSupportTasks["zzz"] == nil)
        #expect(await services.applied.count == 2)
    }

    @Test func adapterRoutesLiveApplyByTheSnapshotsOwnGame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaLiveRoute-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let adapter = ModSupportLaunchAdapter(stores: [ModSupportProfile.zzz.gameID: ModSupportStore(paths: paths, profile: .zzz)])
        let starRail = try #require(try session(paths, game: "starrail", injected: true).injection)
        // No Star Rail store: a Star Rail snapshot is never handed to ZZZ.
        await #expect(throws: LauncherError.self) { try await adapter.applyLive(configuration: starRail) }
        let zzz = try #require(try session(paths, game: "zzz", injected: true).injection)
        // The ZZZ store receives it and fails closed for a missing session.
        await #expect(throws: LauncherError.self) { try await adapter.applyLive(configuration: zzz) }
        #expect(!FileManager.default.fileExists(atPath: zzz.sessionDirectory.path))
    }
}
