// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

extension ModSupportStore {
    /// Reconciles the on-disk library with the managed mod list. Folders copied
    /// into the library in Finder are adopted in place with a stable ID, while
    /// folders that are not safe mods stay untouched and are reported.
    static func refreshLibrary(layout: ModSupportLayout, fileOps: any FileOps) throws -> ModLibraryRefreshResult {
        let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
        var state = try loadState(layout: layout, fs: fs)
        try layout.ensureDirectories(fs, includeMods: state.modsDirectory == nil)
        let library = try libraryFileSystem(state: state, layout: layout, fileOps: fileOps)
        let listing = try library.contentsOfRootDirectoryReportingInvalid()

        struct Candidate {
            let folder: String
            let fileCount: Int
        }
        var candidates: [Candidate] = []
        var rejected = Set(listing.invalid.filter { !$0.hasPrefix(".") })
        for child in listing.paths {
            let folder = child.components.last!
            if folder.hasPrefix(".") { continue }
            do {
                guard let type = try library.itemType(at: child) else { continue }
                switch type {
                case .directory:
                    let scan = try ModSupportFileSystem.scanTree(library, root: child,
                        validateModContent: true, limit: .mod)
                    guard scan.iniCount > 0 else {
                        rejected.insert(folder)
                        continue
                    }
                    candidates.append(Candidate(folder: folder, fileCount: scan.files.count))
                case .regularFile:
                    continue
                case .other:
                    rejected.insert(folder)
                }
            } catch LauncherError.cancelled {
                throw LauncherError.cancelled
            } catch {
                rejected.insert(folder)
            }
        }

        let original = state.mods
        var remaining = original
        var reconciled: [ModSupportState.Mod] = []
        var added = 0
        var updated = 0
        for candidate in candidates {
            let folder = candidate.folder
            guard let name = validateDisplayName(folder), name == folder else {
                rejected.insert(folder)
                continue
            }
            let match = remaining.firstIndex { $0.folderPath == folder }
                ?? remaining.firstIndex { foldedName($0.folderPath) == foldedName(folder) }
                ?? remaining.firstIndex { foldedName($0.name) == foldedName(folder) }
            if let index = match {
                var mod = remaining.remove(at: index)
                let before = mod
                if mod.folderPath != folder {
                    mod.folder = folder
                    if foldedName(mod.name) == foldedName(before.folderPath) {
                        mod.name = name
                    }
                }
                mod.fileCount = candidate.fileCount
                if mod != before { updated += 1 }
                reconciled.append(mod)
                continue
            }

            let base = stableModID(for: name)
            var id = base
            var suffix = 2
            while reconciled.contains(where: { $0.id == id }) || remaining.contains(where: { $0.id == id }) {
                id = "\(base)-\(suffix)"
                suffix += 1
            }
            // A discovery is not an enable action. This also keeps a renamed
            // disabled folder from silently returning enabled under a new ID.
            reconciled.append(.init(id: id, name: name, enabled: false,
                fileCount: candidate.fileCount, folder: folder))
            added += 1
        }

        // A scan failure is not evidence of removal: retain identity and opt-in
        // state so a repaired folder cannot silently become enabled again.
        let retained = remaining.filter { rejected.contains($0.folderPath) }
        reconciled.append(contentsOf: retained)
        state.mods = reconciled
        let changed = state.mods != original
        if changed { try saveState(state, layout: layout, fs: fs) }
        return ModLibraryRefreshResult(added: added, removed: remaining.count - retained.count, updated: updated,
            rejected: rejected.sorted(), changed: changed)
    }
}
