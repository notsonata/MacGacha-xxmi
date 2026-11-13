// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import LauncherCore
import ModSupport

/// What the panel is currently doing. A nil activity means controls are idle.
enum ModSupportActivity: Equatable {
    case installing, repairing, updating, importing, removing, saving, moving, refreshing, applyingLive
}

enum ModSupportViewState: Equatable {
    case loading
    case ready
    case failed(String)
}

@MainActor extension AppModel {
    /// Global Star Rail is the verified profile. Global Zenless Zone Zero uses
    /// the same D3DMetal/D3D11 candidate experimentally. Each game has its own
    /// profile and storage.
    nonisolated static func supportsModSupport(gameID: String) -> Bool {
        ModSupportProfile.find(gameID: gameID) != nil
    }

    static let defaultModSupportGame = ModSupportProfile.starRail.gameID

    /// True when the game's next launch could not inject: its backend is not
    /// D3DMetal, or the selected D3DMetal bundle is not the one injection is
    /// verified on (for example after a newer recommended Wine was selected).
    /// Launch still fails closed; this only explains why in the XXMI panel.
    func modSupportRuntimeIneligible(for gameID: String) -> Bool {
        guard let profile = ModSupportProfile.find(gameID: gameID) else { return false }
        guard launchSettings(for: gameID).backend == .d3dmetal else { return true }
        guard let bundle = effectiveRuntimeManifest?.defaultBundle(for: .d3dmetal) else { return false }
        return bundle.id.rawValue != profile.verifiedRuntimeBundleID
    }

    var modSupportSnapshot: ModSupportSnapshot? { modSupportSnapshots[Self.defaultModSupportGame] }
    var modSupportViewState: ModSupportViewState {
        modSupportViewStates[Self.defaultModSupportGame] ?? .loading
    }
    var modSupportActivity: ModSupportActivity? { modSupportActivities[Self.defaultModSupportGame] }
    var modSupportPackage: BundledXXMIPackage? { modSupportPackages[Self.defaultModSupportGame] }
    var modSupportError: String? { modSupportErrors[Self.defaultModSupportGame] }
    var modSupportTask: Task<Void, Never>? { modSupportTasks[Self.defaultModSupportGame] }

    var isModSupportBusy: Bool { !modSupportActivities.isEmpty }
    var modSupportInstalledVersion: String? { modSupportInstalledVersion(for: Self.defaultModSupportGame) }
    var modSupportAvailableVersion: String? { modSupportAvailableVersion(for: Self.defaultModSupportGame) }
    var modSupportNeedsRiskAcknowledgment: Bool {
        modSupportNeedsRiskAcknowledgment(for: Self.defaultModSupportGame)
    }
    var modSupportModsDirectory: URL? { modSupportModsDirectory(for: Self.defaultModSupportGame) }

    func modSupportSnapshot(for gameID: String) -> ModSupportSnapshot? { modSupportSnapshots[gameID] }
    func modSupportViewState(for gameID: String) -> ModSupportViewState {
        modSupportViewStates[gameID] ?? .loading
    }
    func modSupportActivity(for gameID: String) -> ModSupportActivity? { modSupportActivities[gameID] }
    func modSupportPackage(for gameID: String) -> BundledXXMIPackage? { modSupportPackages[gameID] }
    func modSupportError(for gameID: String) -> String? { modSupportErrors[gameID] }
    func isModSupportBusy(for gameID: String) -> Bool { modSupportActivities[gameID] != nil }
    func modSupportInstalledVersion(for gameID: String) -> String? {
        modSupportSnapshots[gameID]?.installedVersion
    }
    func modSupportAvailableVersion(for gameID: String) -> String? {
        modSupportPackages[gameID]?.manifest.version
    }
    func modSupportNeedsRiskAcknowledgment(for gameID: String) -> Bool {
        modSupportSnapshots[gameID]?.riskAcknowledged == false
    }
    func modSupportModsDirectory(for gameID: String) -> URL? {
        modSupportSnapshots[gameID]?.modsDirectory
    }

    func refreshModSupport(gameID: String = AppModel.defaultModSupportGame) async {
        guard modSupportTasks[gameID] == nil else { return }
        if modSupportSnapshots[gameID] == nil { modSupportViewStates[gameID] = .loading }
        do {
            let snapshot = try await store(for: gameID).snapshot()
            modSupportSnapshots[gameID] = snapshot
            modSupportViewStates[gameID] = .ready
            modSupportErrors[gameID] = nil
        } catch {
            let message = launcherError(error).userMessage
            modSupportErrors[gameID] = message
            if modSupportSnapshots[gameID] == nil { modSupportViewStates[gameID] = .failed(message) }
        }
        if modSupportPackages[gameID] == nil {
            modSupportPackages[gameID] = try? await BundledXXMIPackage.load(gameID: gameID)
        }
    }

    func installBundledModSupport(gameID: String = AppModel.defaultModSupportGame) {
        installBundledModSupport(activity: .installing, gameID: gameID)
    }
    func repairBundledModSupport(gameID: String = AppModel.defaultModSupportGame) {
        installBundledModSupport(activity: .repairing, gameID: gameID)
    }
    func updateBundledModSupport(gameID: String = AppModel.defaultModSupportGame) {
        installBundledModSupport(activity: .updating, gameID: gameID)
    }

    private func installBundledModSupport(activity: ModSupportActivity, gameID: String) {
        runModSupport(activity, gameID: gameID) { store in
            let package = try await BundledXXMIPackage.load(gameID: gameID)
            try await store.install(manifest: package.manifest, archive: package.archiveURL)
        }
    }

    /// Testable seam for the same verified install used by the built-in package.
    func installModSupport(package: BundledXXMIPackage, activity: ModSupportActivity = .installing,
        gameID: String = AppModel.defaultModSupportGame) {
        runModSupport(activity, gameID: gameID) { store in
            try await store.install(manifest: package.manifest, archive: package.archiveURL)
        }
    }

    /// Installs a package the user selected explicitly, without replacing the app.
    func importModSupportPackage(from directory: URL,
        gameID: String = AppModel.defaultModSupportGame) {
        runModSupport(.updating, gameID: gameID) { store in
            let package = try await BundledXXMIPackage.load(directory: directory, gameID: gameID)
            try await store.install(manifest: package.manifest, archive: package.archiveURL)
        }
    }

    func importModSupport(from url: URL, gameID: String = AppModel.defaultModSupportGame) {
        runModSupport(.importing, gameID: gameID) { store in
            try await store.importMod(from: url)
        }
    }

    func setModSupportEnabled(_ id: String, enabled: Bool,
        gameID: String = AppModel.defaultModSupportGame) {
        runModSupport(.saving, gameID: gameID) { store in
            try await store.setModEnabled(id: id, enabled: enabled)
        }
    }

    func removeModSupport(_ id: String, gameID: String = AppModel.defaultModSupportGame) {
        runModSupport(.removing, gameID: gameID) { store in
            try await store.removeMod(id: id)
        }
    }

    func setModSupportInjection(_ enabled: Bool, acknowledgingRisk: Bool,
        gameID: String = AppModel.defaultModSupportGame) {
        runModSupport(.saving, gameID: gameID) { store in
            try await store.setInjectionEnabled(enabled, acknowledgingRisk: acknowledgingRisk)
        }
    }

    func moveModSupportDirectory(to destination: URL,
        gameID: String = AppModel.defaultModSupportGame) {
        runModSupport(.moving, gameID: gameID) { store in
            try await store.moveModsDirectory(to: destination)
        }
    }

    /// Picks up folders the user copied into the library in Finder without
    /// moving or deleting them and reports folders that are not safe mods.
    func rescanModSupportLibrary(gameID: String = AppModel.defaultModSupportGame) {
        guard modSupportTasks[gameID] == nil, canBeginGameOrRuntimeOperation() else { return }
        modSupportActivities[gameID] = .refreshing
        modSupportErrors[gameID] = nil
        let store = store(for: gameID)
        modSupportTasks[gameID] = Task { [weak self] in
            do {
                let result = try await store.refreshModLibrary()
                let snapshot = try await store.snapshot()
                guard let self else { return }
                self.modSupportSnapshots[gameID] = snapshot
                self.modSupportViewStates[gameID] = .ready
                if !result.rejected.isEmpty {
                    self.modSupportErrors[gameID] = String(localized: "Some folders in the mods folder were skipped because they aren't safe mods.")
                }
            } catch {
                guard let self else { return }
                let message = launcherError(error).userMessage
                self.modSupportErrors[gameID] = message
                if self.modSupportSnapshots[gameID] == nil {
                    self.modSupportViewStates[gameID] = .failed(message)
                }
            }
            self?.modSupportActivities[gameID] = nil
            self?.modSupportTasks[gameID] = nil
        }
    }

    private func isRunningLaunchState(_ gameID: String) -> Bool {
        switch launchStates[gameID] {
        case .running, .ready: true
        default: false
        }
    }

    /// Re-reads whether the running session was launched with injection. Only
    /// that session can receive an explicit live update.
    func refreshModLiveApplyEligibility(gameID: String) async {
        guard Self.supportsModSupport(gameID: gameID), isRunningLaunchState(gameID) else {
            modLiveApplyEligibility[gameID] = false
            modLiveApplyPrompts.remove(gameID)
            return
        }
        let session = await launchServices.session(gameID)
        guard isRunningLaunchState(gameID) else { modLiveApplyEligibility[gameID] = false; return }
        let eligible = session?.injection != nil && session?.state == .running
        modLiveApplyEligibility[gameID] = eligible
        if !eligible { modLiveApplyPrompts.remove(gameID) }
    }

    func canApplyModsToRunningGame(gameID: String) -> Bool {
        Self.supportsModSupport(gameID: gameID) && isRunningLaunchState(gameID)
            && modLiveApplyEligibility[gameID] == true
    }

    func showsModLiveApplyPrompt(gameID: String) -> Bool {
        modLiveApplyPrompts.contains(gameID) && canApplyModsToRunningGame(gameID: gameID)
    }

    func dismissModLiveApplyPrompt(gameID: String) {
        modLiveApplyPrompts.remove(gameID)
    }

    /// A manual, explicit request: copy the current enabled mods into the
    /// running game's snapshot. Nothing is sent to the game; the player reloads
    /// mods in game afterwards. Library edits alone only affect the next launch.
    func applyModsToRunningGame(gameID: String = AppModel.defaultModSupportGame) {
        guard modSupportTasks[gameID] == nil, canApplyModsToRunningGame(gameID: gameID),
            canBeginGameOrRuntimeOperation() else { return }
        modSupportActivities[gameID] = .applyingLive
        modSupportErrors[gameID] = nil
        modLiveApplyPrompts.remove(gameID)
        let launchServices = launchServices
        modSupportTasks[gameID] = Task { [weak self] in
            do {
                try await launchServices.applyModsToRunningGame(gameID)
                self?.modLiveApplyPrompts.insert(gameID)
            } catch {
                self?.modSupportErrors[gameID] = launcherError(error).userMessage
            }
            self?.modSupportActivities[gameID] = nil
            self?.modSupportTasks[gameID] = nil
            await self?.refreshModLiveApplyEligibility(gameID: gameID)
        }
    }

    func filteredModSupportMods(matching query: String,
        gameID: String = AppModel.defaultModSupportGame) -> [ManagedMod] {
        let mods = modSupportSnapshots[gameID]?.mods ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return mods }
        return mods.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    func revealModSupportFolder(gameID: String = AppModel.defaultModSupportGame) {
        Task { await revealModSupportLibrary(gameID: gameID) }
    }

    func revealModSupportMod(_ id: String, gameID: String = AppModel.defaultModSupportGame) {
        guard modSupportSnapshots[gameID]?.mods.contains(where: { $0.id == id }) == true else { return }
        Task { await revealModSupportLibrary(gameID: gameID, modID: id) }
    }

    private func revealModSupportLibrary(gameID: String, modID: String? = nil) async {
        do {
            let directory = try await store(for: gameID).modsDirectoryURL()
            let folder = modID.flatMap { id in
                modSupportSnapshots[gameID]?.mods.first { $0.id == id }?.folderPath
            }
            guard modID == nil || folder != nil else { return }
            let url = folder.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            modSupportErrors[gameID] = launcherError(error).userMessage
        }
    }

    /// Serializes store mutations and always republishes the durable snapshot.
    private func runModSupport(_ activity: ModSupportActivity, gameID: String,
        _ operation: @escaping @Sendable (ModSupportStore) async throws -> Void) {
        guard modSupportTasks[gameID] == nil, canBeginGameOrRuntimeOperation() else { return }
        modSupportActivities[gameID] = activity
        modSupportErrors[gameID] = nil
        let store = store(for: gameID)
        modSupportTasks[gameID] = Task { [weak self] in
            do {
                try await operation(store)
                let snapshot = try await store.snapshot()
                guard let self else { return }
                let wasInjecting = self.modSupportSnapshots[gameID]?.injectionEnabled
                self.modSupportSnapshots[gameID] = snapshot
                self.modSupportViewStates[gameID] = .ready
                if wasInjecting != snapshot.injectionEnabled {
                    self.modSupportInjectionDidChange(enabled: snapshot.injectionEnabled)
                }
            } catch {
                guard let self else { return }
                let message = launcherError(error).userMessage
                self.modSupportErrors[gameID] = message
                if self.modSupportSnapshots[gameID] == nil {
                    self.modSupportViewStates[gameID] = .failed(message)
                }
            }
            self?.modSupportActivities[gameID] = nil
            self?.modSupportTasks[gameID] = nil
        }
    }

    private func store(for gameID: String) -> ModSupportStore {
        modSupportStores[gameID] ?? modSupportStore
    }
}
