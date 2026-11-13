// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Session reclamation. Every launch copies the package and enabled mods, so a
/// finished, discarded or orphaned session is moved into this profile's trash
/// (`reclaim-<UUID>` in its staging root) and then deleted in bounded batches.
/// Moves and deletions run detached: cancellation never aborts them.
extension ModSupportStore {
    static let trashPrefix = "reclaim-"
    static let liveStagingPrefix = "live-"

    private static func isOwnedStagingName(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && isCanonicalSessionName(String(name.dropFirst(prefix.count)))
    }

    /// Returns true once `path` no longer exists at its original name.
    static func moveToTrash(_ path: SafeRelativePath, layout: ModSupportLayout,
        fileOps: any FileOps) async -> Bool {
        (try? await BlockingIO.finishing {
            let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
            guard let type = try fs.itemType(at: path) else { return true }
            guard type == .directory else { return false }
            try fs.createDirectory(at: layout.stagingRootRelativePath)
            try fs.moveItem(at: path, to: layout.stagingPath(trashPrefix + UUID().uuidString))
            return true
        }) ?? false
    }

    /// Deletes this profile's trash. Returns how many entries remain.
    static func purgeTrash(layout: ModSupportLayout, fileOps: any FileOps) -> Int {
        guard let fs = try? ContainedFileSystem(root: layout.root, fileOps: fileOps),
            let entries = try? fs.contentsOfDirectory(at: layout.stagingRootRelativePath) else { return 0 }
        var failures = 0
        for path in entries where isOwnedStagingName(path.components.last!, prefix: trashPrefix) {
            do {
                guard try fs.itemType(at: path) == .directory else { failures += 1; continue }
                try fs.removeTreeInBatches(at: path)
            } catch {
                failures += 1
            }
        }
        return failures
    }

    /// Canonical session directories and stale live-apply staging of this
    /// profile only. Star Rail's root also holds `Sessions/zzz` and
    /// `.staging/zzz`; those names are never canonical UUIDs, so they are skipped.
    static func sweepCandidates(layout: ModSupportLayout, fileOps: any FileOps,
        retained: Set<String>) throws -> [SafeRelativePath] {
        let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
        var result: [SafeRelativePath] = []
        if try fs.itemType(at: layout.sessionsRootPath) == .directory {
            for path in try fs.contentsOfDirectory(at: layout.sessionsRootPath) {
                let name = path.components.last!
                guard isCanonicalSessionName(name),
                    try fs.itemType(at: path, allowingLeafSymlink: true) == .directory else { continue }
                let url = layout.sessions.appendingPathComponent(name, isDirectory: true)
                guard !retained.contains(url.standardizedFileURL.path) else { continue }
                result.append(path)
            }
        }
        if try fs.itemType(at: layout.stagingRootRelativePath) == .directory {
            for path in try fs.contentsOfDirectory(at: layout.stagingRootRelativePath)
                where isOwnedStagingName(path.components.last!, prefix: liveStagingPrefix) {
                guard try fs.itemType(at: path, allowingLeafSymlink: true) == .directory else { continue }
                result.append(path)
            }
        }
        return result
    }
}

// MARK: - Live apply

extension ModSupportStore {
    /// Replaces the `Mods` tree of a running, not yet finished launch session
    /// with the current enabled library. The complete tree is staged outside the
    /// include root and published with one atomic directory swap; on any failure
    /// the previous complete tree stays in place. Package files, `d3dx.ini`,
    /// `d3dx_user.ini` and caches are never touched. The game only sees the new
    /// tree after the player reloads it in game.
    public func applyLiveMods(sessionDirectory: URL) async throws -> ModLiveApplyResult {
        let layout = layout, fileOps = fileOps
        defer { schedulePurge() }
        return try await gate.run {
            let container = layout.stagingPath(Self.liveStagingPrefix + UUID().uuidString)
            let result: Result<ModLiveApplyResult, any Error>
            do {
                result = .success(try await BlockingIO.run {
                    try Self.stageAndPublishLiveMods(sessionDirectory: sessionDirectory,
                        container: container, layout: layout, fileOps: fileOps)
                })
            } catch {
                result = .failure(error)
            }
            // After the swap the container holds the previous tree; after a
            // failure it holds partial staging. Either way it is trash, and a
            // leftover is removed by the startup sweep.
            _ = await Self.moveToTrash(container, layout: layout, fileOps: fileOps)
            return try result.get()
        }
    }

    static func stageAndPublishLiveMods(sessionDirectory: URL, container: SafeRelativePath,
        layout: ModSupportLayout, fileOps: any FileOps) throws -> ModLiveApplyResult {
        let name = try canonicalSessionName(for: sessionDirectory, layout: layout)
        let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
        guard try fs.itemType(at: layout.sessionPath(name)) == .directory else {
            throw LauncherError.io("The running launch session is no longer available")
        }
        // The marker exists only between preparation and finish, so a finished
        // or foreign directory is never written.
        guard let payload = try activeSessionPayload(name, layout: layout, fs: fs) else {
            throw LauncherError.io("The running launch session is no longer active")
        }
        let prefix = payload.map { $0.description + "/" } ?? ""
        let modsPath = try SafeRelativePath(layout.sessionPath(name).description + "/" + prefix + "Mods")
        guard try fs.itemType(at: modsPath) == .directory else {
            throw LauncherError.io("The running launch session has no mods folder")
        }
        let state = try loadState(layout: layout, fs: fs)
        guard state.injectionEnabled else {
            throw LauncherError.io("Mod injection is turned off")
        }
        let library = try libraryFileSystem(state: state, layout: layout, fileOps: fileOps)
        try fs.createDirectory(at: layout.stagingRootRelativePath)
        guard try fs.itemType(at: container) == nil else { throw LauncherError.io("Live mod staging already exists") }
        try fs.createDirectory(at: container)
        let staged = try SafeRelativePath(container.description + "/Mods")
        // The same validation as launch preparation: stable `mod.id` folders,
        // no symlinks, no executable content, a present custom library.
        try copyEnabledMods(state: state, library: library, fs: fs, modsPath: staged)
        try fs.synchronizeTree(at: staged)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try fs.publishDirectory(at: staged, to: modsPath)
        return ModLiveApplyResult(enabledMods: state.mods.filter(\.enabled).count)
    }
}
