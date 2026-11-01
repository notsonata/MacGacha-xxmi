// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import LauncherCore
import ModSupport

/// What the panel is currently doing. A nil activity means controls are idle.
enum ModSupportActivity: Equatable {
    case installing, repairing, updating, importing, removing, saving, moving, refreshing
}

enum ModSupportViewState: Equatable {
    case loading
    case ready
    case failed(String)
}

@MainActor extension AppModel {
    /// XXMI is verified for Global Star Rail on the D3DMetal bundle only.
    nonisolated static func supportsModSupport(gameID: String) -> Bool {
        gameID == "starrail"
    }

    var isModSupportBusy: Bool { modSupportActivity != nil }
    var modSupportInstalledVersion: String? { modSupportSnapshot?.installedVersion }
    var modSupportAvailableVersion: String? { modSupportPackage?.manifest.version }
    var modSupportNeedsRiskAcknowledgment: Bool { modSupportSnapshot?.riskAcknowledged == false }
    var modSupportModsDirectory: URL? { modSupportSnapshot?.modsDirectory }

    func refreshModSupport() async {
        guard modSupportTask == nil else { return }
        if modSupportSnapshot == nil { modSupportViewState = .loading }
        do {
            let snapshot = try await modSupportStore.snapshot()
            modSupportSnapshot = snapshot
            modSupportViewState = .ready
            modSupportError = nil
        } catch {
            let message = launcherError(error).userMessage
            modSupportError = message
            if modSupportSnapshot == nil { modSupportViewState = .failed(message) }
        }
        if modSupportPackage == nil { modSupportPackage = try? await BundledXXMIPackage.load() }
    }

    func installBundledModSupport() { installBundledModSupport(activity: .installing) }
    func repairBundledModSupport() { installBundledModSupport(activity: .repairing) }
    func updateBundledModSupport() { installBundledModSupport(activity: .updating) }

    private func installBundledModSupport(activity: ModSupportActivity) {
        runModSupport(activity) { store in
            let package = try await BundledXXMIPackage.load()
            try await store.install(manifest: package.manifest, archive: package.archiveURL)
        }
    }

    /// Testable seam for the same verified install used by the built-in package.
    func installModSupport(package: BundledXXMIPackage, activity: ModSupportActivity = .installing) {
        runModSupport(activity) { store in
            try await store.install(manifest: package.manifest, archive: package.archiveURL)
        }
    }

    /// Installs a package the user selected explicitly, without replacing the app.
    func importModSupportPackage(from directory: URL) {
        runModSupport(.updating) { store in
            let package = try await BundledXXMIPackage.load(directory: directory)
            try await store.install(manifest: package.manifest, archive: package.archiveURL)
        }
    }

    func importModSupport(from url: URL) {
        runModSupport(.importing) { store in
            try await store.importMod(from: url)
        }
    }

    func setModSupportEnabled(_ id: String, enabled: Bool) {
        runModSupport(.saving) { store in
            try await store.setModEnabled(id: id, enabled: enabled)
        }
    }

    func removeModSupport(_ id: String) {
        runModSupport(.removing) { store in
            try await store.removeMod(id: id)
        }
    }

    func setModSupportInjection(_ enabled: Bool, acknowledgingRisk: Bool) {
        runModSupport(.saving) { store in
            try await store.setInjectionEnabled(enabled, acknowledgingRisk: acknowledgingRisk)
        }
    }

    func moveModSupportDirectory(to destination: URL) {
        runModSupport(.moving) { store in
            try await store.moveModsDirectory(to: destination)
        }
    }

    /// Picks up folders the user copied into the library in Finder without
    /// moving or deleting them and reports folders that are not safe mods.
    func rescanModSupportLibrary() {
        guard modSupportTask == nil, canBeginGameOrRuntimeOperation() else { return }
        modSupportActivity = .refreshing
        modSupportError = nil
        let store = modSupportStore
        modSupportTask = Task { [weak self] in
            do {
                let result = try await store.refreshModLibrary()
                let snapshot = try await store.snapshot()
                guard let self else { return }
                self.modSupportSnapshot = snapshot
                self.modSupportViewState = .ready
                if !result.rejected.isEmpty {
                    self.modSupportError = String(localized: "Some folders in the mods folder were skipped because they aren't safe mods.")
                }
            } catch {
                guard let self else { return }
                let message = launcherError(error).userMessage
                self.modSupportError = message
                if self.modSupportSnapshot == nil { self.modSupportViewState = .failed(message) }
            }
            self?.modSupportActivity = nil
            self?.modSupportTask = nil
        }
    }

    func filteredModSupportMods(matching query: String) -> [ManagedMod] {
        let mods = modSupportSnapshot?.mods ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return mods }
        return mods.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    func revealModSupportFolder() {
        Task { await revealModSupportLibrary() }
    }

    func revealModSupportMod(_ id: String) {
        guard modSupportSnapshot?.mods.contains(where: { $0.id == id }) == true else { return }
        Task { await revealModSupportLibrary(modID: id) }
    }

    private func revealModSupportLibrary(modID: String? = nil) async {
        do {
            let directory = try await modSupportStore.modsDirectoryURL()
            let folder = modID.flatMap { id in modSupportSnapshot?.mods.first { $0.id == id }?.folderPath }
            guard modID == nil || folder != nil else { return }
            let url = folder.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            modSupportError = launcherError(error).userMessage
        }
    }

    /// Serializes store mutations and always republishes the durable snapshot.
    private func runModSupport(_ activity: ModSupportActivity,
        _ operation: @escaping @Sendable (ModSupportStore) async throws -> Void) {
        guard modSupportTask == nil, canBeginGameOrRuntimeOperation() else { return }
        modSupportActivity = activity
        modSupportError = nil
        let store = modSupportStore
        modSupportTask = Task { [weak self] in
            do {
                try await operation(store)
                let snapshot = try await store.snapshot()
                guard let self else { return }
                self.modSupportSnapshot = snapshot
                self.modSupportViewState = .ready
            } catch {
                guard let self else { return }
                let message = launcherError(error).userMessage
                self.modSupportError = message
                if self.modSupportSnapshot == nil { self.modSupportViewState = .failed(message) }
            }
            self?.modSupportActivity = nil
            self?.modSupportTask = nil
        }
    }
}
