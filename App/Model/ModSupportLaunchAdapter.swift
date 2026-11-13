// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import Launch
import ModSupport

/// Only Global Star Rail and Global Zenless Zone Zero are opted into the
/// compatibility module. Each game keeps its own store, so one game's persisted
/// injection preference, package and mods never affect another.
struct ModSupportLaunchAdapter: LaunchInjectionPreparing {
    let stores: [String: ModSupportStore]

    init(store: ModSupportStore) {
        self.init(stores: [ModSupportProfile.starRail.gameID: store])
    }

    init(stores: [String: ModSupportStore]) {
        self.stores = stores
    }

    func validateEligibility(game: GameDefinition, settings: LaunchSettings) async throws {
        guard game.id == "zzz", settings.directX12, let store = stores[game.id] else { return }
        if try await store.snapshot().injectionEnabled {
            throw LauncherError.io("Mod injection requires Direct3D 11; turn off DirectX 12 first")
        }
    }

    func prepare(gameID: String, runtimeBundleID: String, backendD3D11: URL) async throws
        -> LaunchInjectionConfiguration? {
        guard let profile = ModSupportProfile.find(gameID: gameID),
            let store = stores[gameID] else { return nil }
        guard let snapshot = try await store.prepareLaunch(gameID: gameID,
            runtimeBundleID: runtimeBundleID, backendD3D11: backendD3D11) else { return nil }
        return LaunchInjectionConfiguration(runnerURL: snapshot.runnerURL,
            injectorURL: snapshot.injectorURL, payloadURL: snapshot.payloadURL,
            sessionDirectory: snapshot.sessionDirectory, gameID: gameID,
            targetExecutable: profile.runnerTarget)
    }

    func prepare(game: GameDefinition, runtimeBundleID: String, backendD3D11: URL,
        settings: LaunchSettings) async throws -> LaunchInjectionConfiguration? {
        guard game.region == .global, let profile = ModSupportProfile.find(gameID: game.id),
            let store = stores[game.id] else { return nil }
        guard let snapshot = try await store.prepareLaunch(gameID: game.id,
            runtimeBundleID: runtimeBundleID, backendD3D11: backendD3D11,
            directX12: settings.directX12) else { return nil }
        return LaunchInjectionConfiguration(runnerURL: snapshot.runnerURL,
            injectorURL: snapshot.injectorURL, payloadURL: snapshot.payloadURL,
            sessionDirectory: snapshot.sessionDirectory, gameID: game.id,
            targetExecutable: profile.runnerTarget)
    }

    func finish(configuration: LaunchInjectionConfiguration) async throws {
        guard let store = stores[configuration.resolvedGameID] else { return }
        _ = try await store.finishLaunch(sessionDirectory: configuration.sessionDirectory)
    }

    func discard(configuration: LaunchInjectionConfiguration) async {
        await stores[configuration.resolvedGameID]?.discardLaunch(sessionDirectory: configuration.sessionDirectory)
    }

    func sweepSessions(gameID: String, retaining: [URL]) async {
        _ = await stores[gameID]?.sweepSessions(retaining: retaining)
    }

    /// Routed by the journaled snapshot's own game, so a reattached ZZZ
    /// session never reaches the Star Rail store or its library.
    func applyLive(configuration: LaunchInjectionConfiguration) async throws {
        guard let store = stores[configuration.resolvedGameID] else {
            throw LauncherError.io("Live mod updates are unavailable for this game")
        }
        _ = try await store.applyLiveMods(sessionDirectory: configuration.sessionDirectory)
    }
}
