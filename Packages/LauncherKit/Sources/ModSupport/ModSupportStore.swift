// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import Synchronization

/// Owns the verified compatibility package, user mod library and per-launch
/// snapshots below `AppPaths.root/XXMI`, with an optional relocated mod library.
/// Every operation is serialized and all
/// filesystem work runs on BlockingIO.
public actor ModSupportStore {
    private nonisolated let runner: any ProcessRunner
    private nonisolated let layout: ModSupportLayout
    private nonisolated let fileOps: any FileOps
    private nonisolated let gate = OperationGate()

    public init(paths: AppPaths, runner: any ProcessRunner = SystemProcessRunner()) {
        self.runner = runner
        self.fileOps = SystemFileOps()
        layout = ModSupportLayout(paths: paths)
    }

    init(paths: AppPaths, runner: any ProcessRunner = SystemProcessRunner(), fileOps: any FileOps) {
        self.runner = runner
        self.fileOps = fileOps
        layout = ModSupportLayout(paths: paths)
    }

    /// The library the store currently reads, including a custom location whose
    /// volume may be unavailable. Import and launch operations fail closed there.
    public func modsDirectoryURL() async throws -> URL {
        let layout = layout, fileOps = fileOps
        return try await gate.run {
            try await BlockingIO.run {
                let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
                let state = try Self.loadState(layout: layout, fs: fs)
                return layout.libraryDirectory(for: state)
            }
        }
    }

    /// Copies and verifies the managed library at an exact new folder, then
    /// persists that selection before removing the old library.
    public func moveModsDirectory(to destination: URL) async throws {
        let layout = layout, fileOps = fileOps
        try await gate.run {
            try await BlockingIO.run {
                try Self.relocateLibrary(to: destination, layout: layout, fileOps: fileOps)
            }
        }
    }

    /// Adopts folders placed directly in the library without moving or deleting
    /// them. Unsafe folders are reported and left in place.
    public func refreshModLibrary() async throws -> ModLibraryRefreshResult {
        let layout = layout, fileOps = fileOps
        return try await gate.run {
            try await BlockingIO.run {
                try Self.refreshLibrary(layout: layout, fileOps: fileOps)
            }
        }
    }

    /// Called only after a launch is verifiably over. Copies the SRMI user file
    /// out of that launch's immutable snapshot so later launches can start with
    /// the settings the player saved. A session that began from an older
    /// revision never overwrites newer settings.
    public func finishLaunch(sessionDirectory: URL) async throws -> ModUserSettingsOutcome {
        let layout = layout, fileOps = fileOps
        return try await gate.run {
            try await BlockingIO.run {
                try Self.finishLaunch(sessionDirectory: sessionDirectory, layout: layout, fileOps: fileOps)
            }
        }
    }

    /// Durable installation, preference and mod-library state.
    public func snapshot() async throws -> ModSupportSnapshot {
        let layout = layout, fileOps = fileOps
        return try await gate.run {
            try await BlockingIO.run {
                let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
                let state = try Self.loadState(layout: layout, fs: fs)
                let installed = try Self.installedManifest(layout: layout, fs: fs, state: state, strict: false)
                return state.snapshot(installedVersion: installed?.version,
                    modsDirectory: layout.libraryDirectory(for: state))
            }
        }
    }

    /// Stages the external archive, verifies every declared file, then atomically
    /// publishes the version without changing mods or preferences.
    public func install(manifest: ModPackageManifest, archive: URL) async throws {
        let layout = layout, runner = runner, fileOps = fileOps
        try await gate.run {
            try await BlockingIO.run {
                try manifest.validate()
                guard manifest.gameID == ModSupportConstants.gameID,
                    manifest.supportedRuntimeBundleIDs.contains(ModSupportConstants.runtimeBundleID) else {
                    throw LauncherError.io("Mod package does not support Honkai: Star Rail on the verified runtime")
                }
                let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
                let state = try Self.loadState(layout: layout, fs: fs)
                try layout.ensureDirectories(fs, includeMods: state.modsDirectory == nil)
                let stagedName = "install-\(UUID().uuidString)"
                let stagedPath = layout.stagingPath(stagedName)
                var shouldRemoveStaged = true
                defer { if shouldRemoveStaged { try? fs.removeItem(at: stagedPath) } }
                let archivePath = layout.stagingPath("archive-\(UUID().uuidString)")
                defer { try? fs.removeItem(at: archivePath) }
                try Self.stageArchiveCopy(source: archive, to: archivePath, fs: fs,
                    expectedSize: manifest.archiveSize, limit: ModPackageManifest.maximumArchiveBytes)
                try Self.verifyArchive(manifest: manifest, archive: archivePath, fs: fs)
                let stagedURL = stagedPath.resolved(against: layout.root)
                let extractor = ArchiveExtractor(runner: runner,
                    maxExpandedBytes: ModPackageManifest.maximumExpandedBytes,
                    maxEntries: ModPackageManifest.maximumFileCount)
                try await extractor.extract(archivePath.resolved(against: layout.root), format: .zip, into: stagedURL)
                try Self.verifyExtractedPackage(manifest: manifest, layout: layout, stagedName: stagedName)
                for file in manifest.files {
                    try fs.fullSync(at: SafeRelativePath(stagedPath.description + "/" + file.path))
                }

                let versionPath = layout.packagePath(for: manifest.version)
                let manifestPath = layout.manifestPath(for: manifest.version)
                let oldManifest: Data?
                if let type = try fs.itemType(at: manifestPath) {
                    guard type == .regularFile else { throw LauncherError.unsafePath(manifestPath.description) }
                    oldManifest = try fs.readFile(at: manifestPath,
                        maxBytes: ModPackageManifest.maximumEncodedBytes)
                } else {
                    oldManifest = nil
                }
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let replaced = try fs.publishDirectory(at: stagedPath, to: versionPath)
                do {
                    let manifestData = try Self.encodeManifest(manifest)
                    try Self.writeAtomicallyReconciled(manifestData, to: manifestPath, fs: fs)
                    var updated = state
                    updated.activeVersion = manifest.version
                    try Self.saveState(updated, layout: layout, fs: fs)
                } catch {
                    if !Self.rollbackInstall(replaced: replaced, stagedPath: stagedPath,
                        versionPath: versionPath, manifestPath: manifestPath, oldManifest: oldManifest, fs: fs) {
                        shouldRemoveStaged = false
                    }
                    throw error
                }
            }
        }
    }

    /// Stages a folder or ZIP and publishes it under a stable, unique ID.
    public func importMod(from source: URL) async throws {
        let layout = layout, runner = runner, fileOps = fileOps
        try await gate.run {
            try await BlockingIO.run {
                try await Self.importMod(source: source, layout: layout, runner: runner, fileOps: fileOps)
            }
        }
    }

    public func setModEnabled(id: String, enabled: Bool) async throws {
        let layout = layout, fileOps = fileOps
        try await gate.run {
            try await BlockingIO.run {
                _ = try SafeIdentifier(id)
                let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
                var state = try Self.loadState(layout: layout, fs: fs)
                guard let index = state.mods.firstIndex(where: { $0.id == id }) else {
                    throw LauncherError.io("Mod is not imported")
                }
                guard state.mods[index].enabled != enabled else { return }
                state.mods[index].enabled = enabled
                try Self.saveState(state, layout: layout, fs: fs)
            }
        }
    }

    /// Removes the library entry and its copied files without touching the source.
    public func removeMod(id: String) async throws {
        let layout = layout, fileOps = fileOps
        try await gate.run {
            try await BlockingIO.run {
                _ = try SafeIdentifier(id)
                let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
                var state = try Self.loadState(layout: layout, fs: fs)
                guard let index = state.mods.firstIndex(where: { $0.id == id }) else {
                    throw LauncherError.io("Mod is not imported")
                }
                try layout.ensureDirectories(fs, includeMods: state.modsDirectory == nil)
                let library = try Self.libraryFileSystem(state: state, layout: layout,
                    fileOps: fileOps)
                let modPath = try SafeRelativePath(state.mods[index].folderPath)
                let quarantineName = ".macgacha-remove-\(UUID().uuidString)"
                let quarantinePath = try SafeRelativePath(quarantineName)
                let hasFiles = try library.itemType(at: modPath) != nil
                if hasFiles { try library.moveItem(at: modPath, to: quarantinePath) }
                state.mods.remove(at: index)
                do {
                    try Self.saveState(state, layout: layout, fs: fs)
                } catch {
                    if hasFiles { try? library.moveItem(at: quarantinePath, to: modPath) }
                    throw error
                }
                if hasFiles { try? library.removeItem(at: quarantinePath) }
            }
        }
    }

    /// The first enable requires an explicit risk acknowledgment.
    public func setInjectionEnabled(_ enabled: Bool, acknowledgingRisk: Bool) async throws {
        let layout = layout, fileOps = fileOps
        try await gate.run {
            try await BlockingIO.run {
                let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
                var state = try Self.loadState(layout: layout, fs: fs)
                if enabled {
                    guard state.riskAcknowledged || acknowledgingRisk else {
                        throw LauncherError.consentRequired("Mod injection requires acknowledging the ban risk")
                    }
                    if acknowledgingRisk { state.riskAcknowledged = true }
                }
                state.injectionEnabled = enabled
                try Self.saveState(state, layout: layout, fs: fs)
            }
        }
    }

    /// Returns nil while injection is off. Otherwise re-verifies the installed
    /// package and copies it plus enabled mods into an immutable launch session.
    public func prepareLaunch(gameID: String, runtimeBundleID: String, backendD3D11: URL) async throws -> PreparedModLaunch? {
        let layout = layout, fileOps = fileOps
        return try await gate.run {
            try await BlockingIO.run {
                let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
                let state = try Self.loadState(layout: layout, fs: fs)
                guard state.injectionEnabled else { return nil }
                guard gameID == ModSupportConstants.gameID else {
                    throw LauncherError.io("Mod injection supports Honkai: Star Rail only")
                }
                guard runtimeBundleID == ModSupportConstants.runtimeBundleID else {
                    throw LauncherError.io("Mod injection is unavailable for this runtime")
                }
                guard let version = state.activeVersion else {
                    throw LauncherError.io("Mod support is not installed")
                }
                guard let manifest = try Self.installedManifest(layout: layout, fs: fs, state: state, strict: true),
                    manifest.version == version,
                    manifest.gameID == ModSupportConstants.gameID,
                    manifest.supportedRuntimeBundleIDs.contains(runtimeBundleID) else {
                    throw LauncherError.io("The installed mod package is incompatible")
                }
                let backend = try ModBackendPath.windowsPath(for: backendD3D11)
                try layout.ensureDirectories(fs, includeMods: state.modsDirectory == nil)
                let library = try Self.libraryFileSystem(state: state, layout: layout,
                    fileOps: fileOps)
                let sessionName = UUID().uuidString
                let sessionPath = layout.sessionPath(sessionName)
                guard try fs.itemType(at: sessionPath) == nil else {
                    throw LauncherError.io("Launch session already exists")
                }
                try fs.createDirectory(at: sessionPath)
                do {
                    try Self.copyPackage(manifest: manifest, layout: layout, fs: fs, sessionPath: sessionPath)
                    let payloadDirectory = try Self.payloadDirectory(for: manifest)
                    let modsPath = try SafeRelativePath(sessionPath.description + "/"
                        + (payloadDirectory.map { $0.description + "/" } ?? "") + "Mods")
                    try Self.copyEnabledMods(state: state, library: library, fs: fs,
                        modsPath: modsPath)
                    try Self.configureD3DX(fs: fs, sessionPath: sessionPath,
                        payloadDirectory: payloadDirectory, backend: backend)
                    try Self.seedUserConfig(fs: fs, layout: layout, sessionName: sessionName,
                        payloadDirectory: payloadDirectory)
                    let runnerPath = try Self.sessionFile(manifest.runnerPath, sessionPath: sessionPath)
                    let injectorPath = try Self.sessionFile(manifest.injectorPath, sessionPath: sessionPath)
                    let payloadPath = try Self.sessionFile(manifest.payloadPath, sessionPath: sessionPath)
                    for path in [runnerPath, injectorPath, payloadPath] {
                        guard try fs.itemType(at: path) == .regularFile else {
                            throw LauncherError.io("Prepared launch file is missing")
                        }
                    }
                    return PreparedModLaunch(runnerURL: runnerPath.resolved(against: layout.root),
                        injectorURL: injectorPath.resolved(against: layout.root),
                        payloadURL: payloadPath.resolved(against: layout.root),
                        sessionDirectory: sessionPath.resolved(against: layout.root))
                } catch {
                    try? fs.removeItem(at: sessionPath)
                    throw error
                }
            }
        }
    }
}

// MARK: - State

extension ModSupportStore {
    /// The default library may be initialized on first use. A custom library
    /// must already exist: a missing volume never becomes a new empty library.
    static func libraryFileSystem(state: ModSupportState, layout: ModSupportLayout,
        fileOps: any FileOps) throws -> ContainedFileSystem {
        let url = layout.libraryDirectory(for: state)
        let library = try ContainedFileSystem(root: url, fileOps: fileOps)
        if state.modsDirectory != nil {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            let managed = layout.xxmiRoot.resolvingSymlinksInPath().standardizedFileURL
            let managedPrefix = managed.path.hasSuffix("/") ? managed.path : managed.path + "/"
            guard canonical.path != managed.path, !canonical.path.hasPrefix(managedPrefix) else {
                throw LauncherError.unsafePath(canonical.path)
            }
            guard let pinned = try library.pinRootIfPresent() else {
                throw LauncherError.io("Mod library is unavailable at its selected location")
            }
            return pinned
        }
        return library
    }

    static func loadState(layout: ModSupportLayout, fs: ContainedFileSystem) throws -> ModSupportState {
        guard try fs.itemType(at: layout.statePath) != nil else { return ModSupportState() }
        let data: Data
        do { data = try fs.readFile(at: layout.statePath, maxBytes: ModSupportConstants.maximumStateBytes) }
        catch LauncherError.fileTooLarge {
            throw LauncherError.journalCorrupt("mod support state is too large")
        }
        do {
            let state = try JSONDecoder().decode(ModSupportState.self, from: data)
            try state.validate()
            return state
        } catch is LauncherError {
            throw LauncherError.journalCorrupt("mod support state is invalid")
        } catch {
            throw LauncherError.journalCorrupt("mod support state is invalid")
        }
    }

    static func saveState(_ state: ModSupportState, layout: ModSupportLayout, fs: ContainedFileSystem) throws {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        guard data.count <= ModSupportConstants.maximumStateBytes else {
            throw LauncherError.io("mod support state exceeds its size limit")
        }
        try writeAtomicallyReconciled(data, to: layout.statePath, fs: fs)
    }

    /// A parent-directory fsync may fail after the rename already made the new
    /// bytes visible. Callers compensate for failed operations, so treat the
    /// committed readback as success instead of undoing durable visible state.
    static func writeAtomicallyReconciled(_ data: Data, to path: SafeRelativePath,
        fs: ContainedFileSystem) throws {
        do {
            try fs.writeAtomically(data, to: path)
        } catch {
            guard !Task.isCancelled else { throw error }
            if let current = try? fs.readFile(at: path, maxBytes: max(data.count, 1)), current == data {
                return
            }
            throw error
        }
    }

    /// Restores the pre-publication version directory and manifest after a
    /// pre-commit failure. Returns false when the old directory could not be
    /// moved back and must be retained in staging rather than deleted.
    @discardableResult
    static func rollbackInstall(replaced: Bool, stagedPath: SafeRelativePath,
        versionPath: SafeRelativePath, manifestPath: SafeRelativePath, oldManifest: Data?,
        fs: ContainedFileSystem) -> Bool {
        var removeStaged = true
        if replaced {
            do {
                _ = try fs.publishDirectory(at: stagedPath, to: versionPath)
            } catch {
                removeStaged = false
            }
        } else {
            try? fs.removeItem(at: versionPath)
        }
        guard removeStaged else { return false }
        do {
            if let oldManifest {
                try writeAtomicallyReconciled(oldManifest, to: manifestPath, fs: fs)
            } else {
                try fs.removeFile(at: manifestPath)
            }
        } catch {
            return false
        }
        return true
    }

    static func encodeManifest(_ manifest: ModPackageManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= ModPackageManifest.maximumEncodedBytes else {
            throw LauncherError.io("Mod package manifest exceeds its size limit")
        }
        return data
    }

    static func installedManifest(layout: ModSupportLayout, fs: ContainedFileSystem,
        state: ModSupportState, strict: Bool) throws -> ModPackageManifest? {
        guard let version = state.activeVersion else { return nil }
        let path = layout.manifestPath(for: version)
        do {
            guard try fs.itemType(at: path) == .regularFile else {
                if strict { throw LauncherError.io("The installed mod package metadata is missing") }
                return nil
            }
            let data = try fs.readFile(at: path, maxBytes: ModPackageManifest.maximumEncodedBytes)
            let manifest = try JSONDecoder().decode(ModPackageManifest.self, from: data)
            try manifest.validate()
            guard manifest.version == version, manifest.gameID == ModSupportConstants.gameID,
                manifest.supportedRuntimeBundleIDs.contains(ModSupportConstants.runtimeBundleID) else {
                throw LauncherError.io("Installed mod package is incompatible")
            }
            let packagePath = layout.packagePath(for: version)
            guard try fs.itemType(at: packagePath) == .directory else {
                if strict { throw LauncherError.io("The installed mod package is missing") }
                return nil
            }
            for file in manifest.files {
                let filePath = try SafeRelativePath(packagePath.description + "/" + file.path)
                guard let actual = try fs.size(at: filePath) else {
                    if strict { throw LauncherError.io("The installed mod package is incomplete") }
                    return nil
                }
                guard actual == file.size else {
                    if strict { throw LauncherError.sizeMismatch(path: file.path,
                        expected: file.size, actual: actual) }
                    return nil
                }
            }
            return manifest
        } catch LauncherError.cancelled {
            throw LauncherError.cancelled
        } catch let error as LauncherError {
            if strict { throw error }
            return nil
        } catch {
            if strict { throw LauncherError.journalCorrupt("installed mod package metadata is invalid") }
            return nil
        }
    }
}
