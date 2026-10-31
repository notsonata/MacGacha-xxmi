// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

extension ModSupportStore {
    /// Copies the whole managed library into an exact new folder and only then
    /// commits the location. The old library is removed after the commit, so a
    /// failure at any earlier point leaves the previous library usable.
    static func relocateLibrary(to destination: URL, layout: ModSupportLayout,
        fileOps: any FileOps) throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"),
            !destination.path.isEmpty, !destination.path.utf8.contains(0) else {
            throw LauncherError.io("Mod library destination must be a local folder")
        }
        let appFS = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
        let state = try loadState(layout: layout, fs: appFS)
        let sourceURL = layout.libraryDirectory(for: state)
        let destinationURL = URL(fileURLWithPath: destination.path, isDirectory: true)
        let canonicalSource = canonical(sourceURL)
        let canonicalDestination = canonical(destinationURL)

        if canonicalSource.path == canonicalDestination.path { return }
        if state.modsDirectory == nil {
            try layout.ensureDirectories(appFS, includeMods: true)
        }
        let sourceHandle = try ContainedFileSystem(root: sourceURL, fileOps: fileOps)
        guard let sourceFS = try sourceHandle.pinRootIfPresent() else {
            throw LauncherError.io("Mod library is unavailable at its selected location")
        }

        let sourceIdentity = try sourceFS.rootIdentity()

        try validateDestination(destinationURL, canonicalDestination: canonicalDestination,
            canonicalSource: canonicalSource, layout: layout, fileOps: fileOps)

        let parent = destinationURL.deletingLastPathComponent()
        let leaf = try SafeRelativePath(destinationURL.lastPathComponent)
        let parentFS = try ContainedFileSystem(root: parent, fileOps: fileOps)
        let existed = try parentFS.itemType(at: leaf) != nil
        if !existed {
            do {
                try parentFS.createDirectory(at: leaf)
            } catch {
                try? parentFS.removeEmptyDirectory(at: leaf)
                throw error
            }
        }
        let destinationFS = try ContainedFileSystem(root: destinationURL, fileOps: fileOps).pinRoot()

        var copied: [SafeRelativePath] = []
        do {
            try copyLibrary(from: sourceFS, to: destinationFS, copied: &copied)
            var updated = state
            updated.modsDirectory = canonicalDestination.path == canonical(layout.modsDirectory).path
                ? nil : destinationURL.path
            try saveState(updated, layout: layout, fs: appFS)
        } catch {
            if existed {
                for child in copied { try? destinationFS.removeItem(at: child) }
            } else {
                // The whole leaf was created by this operation, so every entry
                // below it belongs to the failed copy.
                try? parentFS.removeItem(at: leaf)
            }
            throw error
        }

        // Cleanup cannot turn a committed relocation into a reported failure,
        // and a replacement directory at the old name is never ours to remove.
        do {
            let sourceParentFS = try ContainedFileSystem(root: sourceURL.deletingLastPathComponent(),
                fileOps: fileOps)
            let sourceLeaf = try SafeRelativePath(sourceURL.lastPathComponent)
            if let current = try sourceParentFS.pinDirectoryIfPresent(at: sourceLeaf),
                try current.rootIdentity() == sourceIdentity {
                try? sourceParentFS.removeItem(at: sourceLeaf)
            }
        } catch { /* The verified new library is authoritative; keep the old data. */ }
    }

    private static func validateDestination(_ destination: URL, canonicalDestination: URL,
        canonicalSource: URL, layout: ModSupportLayout, fileOps: any FileOps) throws {
        guard destination.path != "/", !destination.lastPathComponent.isEmpty else {
            throw LauncherError.unsafePath(destination.path)
        }
        let managed = canonical(layout.xxmiRoot)
        let isDefaultLibrary = canonicalDestination.path == canonical(layout.modsDirectory).path
        if !isDefaultLibrary,
            canonicalDestination.path == managed.path || isDescendant(canonicalDestination, of: managed) {
            throw LauncherError.unsafePath(destination.path)
        }
        if isDescendant(canonicalDestination, of: canonicalSource)
            || isDescendant(canonicalSource, of: canonicalDestination) {
            throw LauncherError.unsafePath(destination.path)
        }

        let parentFS = try ContainedFileSystem(root: destination.deletingLastPathComponent(),
            fileOps: fileOps)
        guard try parentFS.pinRootIfPresent() != nil else {
            throw LauncherError.io("Mod library destination folder is missing")
        }
        let leaf = try SafeRelativePath(destination.lastPathComponent)
        guard let existing = try parentFS.itemType(at: leaf) else { return }
        guard existing == .directory else { throw LauncherError.unsafePath(destination.path) }
        guard try parentFS.contentsOfDirectory(at: leaf).isEmpty else {
            throw LauncherError.io("Mod library destination is not empty")
        }
    }

    private static func copyLibrary(from source: ContainedFileSystem, to destination: ContainedFileSystem,
        copied: inout [SafeRelativePath]) throws {
        let limit = ModSupportConstants.Limits.library
        var totalBytes: Int64 = 0
        var totalEntries = 0
        for child in try source.contentsOfRootDirectory().sorted(by: {
            $0.description < $1.description
        }) {
            guard try destination.itemType(at: child) == nil else {
                throw LauncherError.io("Mod library destination is not empty")
            }
            switch try source.itemType(at: child) {
            case .directory:
                let sourceScan = try ModSupportFileSystem.scanTree(source, root: child,
                    validateModContent: false, limit: limit)
                try add(sourceScan.totalBytes, sourceScan.entries, to: &totalBytes,
                    entries: &totalEntries, limit: limit)
                copied.append(child)
                _ = try ModSupportFileSystem.copyContents(from: source, sourceDirectory: child,
                    to: destination, destinationDirectory: child, validateModContent: false,
                    limit: limit)
                try destination.synchronizeTree(at: child)
                try verify(child, source: source, destination: destination, limit: limit)
            case .regularFile:
                guard let size = try source.size(at: child), size >= 0 else {
                    throw LauncherError.io("Mod library file size is invalid")
                }
                try add(size, 1, to: &totalBytes, entries: &totalEntries, limit: limit)
                copied.append(child)
                let written = try source.copyRegularFile(at: child, to: child, in: destination,
                    maxBytes: limit.bytes)
                try destination.fullSync(at: child)
                guard written == size, try destination.size(at: child) == size else {
                    throw LauncherError.io("Mod library copy verification failed")
                }
                try verifyFile(child, source: source, destination: destination)
            case .other:
                throw LauncherError.unsafePath(child.description)
            case .none:
                throw LauncherError.io("Mod library changed while copying")
            }
        }
    }

    private static func add(_ bytes: Int64, _ entries: Int, to totalBytes: inout Int64,
        entries totalEntries: inout Int, limit: ModSupportConstants.Limits) throws {
        let (sum, overflow) = totalBytes.addingReportingOverflow(bytes)
        let (count, countOverflow) = totalEntries.addingReportingOverflow(entries)
        guard !overflow, !countOverflow, sum <= limit.bytes, count <= limit.entries else {
            throw LauncherError.fileTooLarge(path: "mod library", limit: Int(clamping: limit.bytes))
        }
        totalBytes = sum
        totalEntries = count
    }

    private static func verify(_ root: SafeRelativePath, source: ContainedFileSystem,
        destination: ContainedFileSystem, limit: ModSupportConstants.Limits) throws {
        let sourceScan = try ModSupportFileSystem.scanTree(source, root: root,
            validateModContent: false, limit: limit)
        let destinationScan = try ModSupportFileSystem.scanTree(destination, root: root,
            validateModContent: false, limit: limit)
        guard sourceScan.files == destinationScan.files,
            sourceScan.directories == destinationScan.directories else {
            throw LauncherError.io("Mod library copy verification failed")
        }
        for relative in sourceScan.files.keys.sorted() {
            let path = try SafeRelativePath(root.description + "/" + relative)
            try verifyFile(path, relative: relative, source: source, destination: destination)
        }
    }

    private static func verifyFile(_ path: SafeRelativePath, relative: String? = nil,
        source: ContainedFileSystem, destination: ContainedFileSystem) throws {
        let expected = try ModSupportFileSystem.digest(source, at: path)
        let actual = try ModSupportFileSystem.digest(destination, at: path)
        guard expected == actual else {
            throw LauncherError.digestMismatch(path: relative ?? path.description,
                expected: expected.hex, actual: actual.hex)
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let child = url.pathComponents, base = parent.pathComponents
        guard child.count > base.count else { return false }
        return Array(child.prefix(base.count)) == base
    }
}
