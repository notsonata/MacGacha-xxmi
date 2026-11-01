// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

extension ModSupportStore {
    /// Copies an external archive into the private staging tree and validates the
    /// retained copy. Extraction and digest checks never reopen the mutable source.
    static func stageArchiveCopy(source: URL, to destination: SafeRelativePath,
        fs: ContainedFileSystem, expectedSize: Int64?, limit: Int64) throws {
        guard source.isFileURL, source.path.hasPrefix("/"), !source.lastPathComponent.isEmpty else {
            throw LauncherError.io("Mod archive must be a local file")
        }
        let name = source.lastPathComponent
        let sourceFS = try ContainedFileSystem(root: source.deletingLastPathComponent())
        let sourcePath = try SafeRelativePath(name)
        guard try sourceFS.itemType(at: sourcePath) == .regularFile,
            let sourceSize = try sourceFS.size(at: sourcePath) else {
            throw LauncherError.io("Mod archive is missing")
        }
        if let expectedSize, sourceSize != expectedSize {
            throw LauncherError.sizeMismatch(path: name, expected: expectedSize, actual: sourceSize)
        }
        guard sourceSize <= limit else {
            throw LauncherError.fileTooLarge(path: name, limit: Int(clamping: limit))
        }
        let input = try sourceFS.openForReading(at: sourcePath)
        defer { try? input.close() }
        let output = try fs.openForWriting(at: destination, truncate: true)
        var copied: Int64 = 0
        do {
            while true {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let data = try autoreleasepool { try input.read(upToCount: 65_536) ?? Data() }
                if data.isEmpty { break }
                let (sum, overflow) = copied.addingReportingOverflow(Int64(data.count))
                let bound = expectedSize ?? sourceSize
                guard !overflow, sum <= limit, sum <= bound else {
                    throw LauncherError.sizeMismatch(path: name, expected: bound, actual: sum)
                }
                try output.write(contentsOf: data)
                copied = sum
            }
        } catch {
            try? output.close()
            throw error
        }
        try output.close()
        let expected = expectedSize ?? sourceSize
        guard copied == expected else {
            throw LauncherError.sizeMismatch(path: name, expected: expected, actual: copied)
        }
        try fs.fullSync(at: destination)
    }

    static func verifyArchive(manifest: ModPackageManifest, archive: SafeRelativePath,
        fs: ContainedFileSystem) throws {
        let name = archive.components.last!
        guard try fs.itemType(at: archive) == .regularFile, let size = try fs.size(at: archive) else {
            throw LauncherError.io("Mod package archive is missing")
        }
        guard size == manifest.archiveSize else {
            throw LauncherError.sizeMismatch(path: name,
                expected: manifest.archiveSize, actual: size)
        }
        let digest = try ModSupportFileSystem.digest(fs, at: archive)
        let expected = try Digest(algorithm: .sha256, hex: manifest.archiveSHA256)
        guard digest == expected else {
            throw LauncherError.digestMismatch(path: name,
                expected: manifest.archiveSHA256, actual: digest.hex)
        }
    }

    static func verifyExtractedPackage(manifest: ModPackageManifest, layout: ModSupportLayout,
        stagedName: String) throws {
        let fs = try ContainedFileSystem(root: layout.staging)
        let root = try SafeRelativePath(stagedName)
        let scan = try ModSupportFileSystem.scanTree(fs, root: root, validateModContent: false,
            limit: .package)
        let declared = Set(manifest.files.map(\.path))
        guard declared == Set(scan.files.keys) else {
            throw LauncherError.io(scan.files.count < declared.count
                ? "Mod package is missing declared files" : "Mod package contains undeclared files")
        }
        guard impliedDirectories(declared) == scan.directories else {
            throw LauncherError.io("Mod package contains undeclared directories")
        }
        for file in manifest.files {
            let path = try SafeRelativePath(root.description + "/" + file.path)
            guard scan.files[file.path] == file.size else {
                throw LauncherError.sizeMismatch(path: file.path, expected: file.size,
                    actual: scan.files[file.path] ?? -1)
            }
            let digest = try ModSupportFileSystem.digest(fs, at: path)
            let expected = try Digest(algorithm: .sha256, hex: file.sha256)
            guard digest == expected else {
                throw LauncherError.digestMismatch(path: file.path, expected: file.sha256, actual: digest.hex)
            }
        }
    }

    static func importMod(source: URL, layout: ModSupportLayout,
        runner: any ProcessRunner, fileOps: any FileOps) async throws {
        guard source.isFileURL, source.path.hasPrefix("/"), !source.lastPathComponent.isEmpty else {
            throw LauncherError.io("Mod import must be a local folder or ZIP archive")
        }
        let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
        var state = try loadState(layout: layout, fs: fs)
        let sourceFS = try ContainedFileSystem(root: source.deletingLastPathComponent())
        let sourcePath = try SafeRelativePath(source.lastPathComponent)
        guard let type = try sourceFS.itemType(at: sourcePath, allowingLeafSymlink: true) else {
            throw LauncherError.io("Mod import source is missing")
        }
        try layout.ensureDirectories(fs, includeMods: state.modsDirectory == nil)
        let library = try libraryFileSystem(state: state, layout: layout, fileOps: fileOps)
        let importName = "import-\(UUID().uuidString)"
        let importRoot = layout.stagingPath(importName)
        defer { try? fs.removeItem(at: importRoot) }

        let modPath: SafeRelativePath
        var name: String
        var fileCount: Int
        switch type {
        case .directory:
            name = sourcePath.components.last!
            let staged = try SafeRelativePath(importRoot.description + "/mod")
            let scan = try ModSupportFileSystem.copyContents(from: sourceFS, sourceDirectory: sourcePath,
                to: fs, destinationDirectory: staged, validateModContent: true, limit: .mod)
            guard scan.iniCount > 0 else { throw LauncherError.io("Mod package contains no INI file") }
            fileCount = scan.files.count
            modPath = staged
        case .regularFile:
            guard sourcePath.components.last!.lowercased().hasSuffix(".zip") else {
                throw LauncherError.io("Mod import supports folders and ZIP archives")
            }
            let archivePath = try SafeRelativePath(importRoot.description + "/source.zip")
            try stageArchiveCopy(source: source, to: archivePath, fs: fs, expectedSize: nil,
                limit: ModSupportConstants.maximumModBytes)
            let extracted = try SafeRelativePath(importRoot.description + "/extracted")
            let extractor = ArchiveExtractor(runner: runner,
                maxExpandedBytes: ModSupportConstants.maximumModBytes,
                maxEntries: ModSupportConstants.maximumModFiles)
            try await extractor.extract(archivePath.resolved(against: layout.root), format: .zip,
                into: extracted.resolved(against: layout.root))
            let children = try fs.contentsOfDirectory(at: extracted)
            let onlyDirectory = children.count == 1
                ? try fs.itemType(at: children[0], allowingLeafSymlink: true) == .directory
                : false
            if onlyDirectory {
                modPath = children[0]
                name = modPath.components.last!
            } else {
                modPath = extracted
                name = source.deletingPathExtension().lastPathComponent
            }
            let scan = try ModSupportFileSystem.scanTree(fs, root: modPath, validateModContent: true,
                limit: .mod)
            guard scan.iniCount > 0 else { throw LauncherError.io("Mod package contains no INI file") }
            fileCount = scan.files.count
        case .other:
            throw LauncherError.unsafePath(sourcePath.description)
        }

        guard let validatedName = validateDisplayName(name) else {
            throw LauncherError.io("Mod name is invalid")
        }
        name = validatedName
        let id = stableModID(for: name)
        let destination = try SafeRelativePath(id)
        guard !state.mods.contains(where: { foldedName($0.name) == foldedName(name) }),
            !state.mods.contains(where: { $0.id == id }),
            try library.itemType(at: destination) == nil else {
            throw LauncherError.io("A mod with this name is already imported")
        }
        do {
            let scan = try ModSupportFileSystem.copyContents(from: fs, sourceDirectory: modPath,
                to: library, destinationDirectory: destination, validateModContent: true, limit: .mod)
            guard scan.files.count == fileCount else {
                throw LauncherError.io("Mod source changed during import")
            }
            try library.synchronizeTree(at: destination)
            state.mods.append(.init(id: id, name: name, enabled: true, fileCount: fileCount))
            try saveState(state, layout: layout, fs: fs)
        } catch {
            // This destination was absent before this import. A failed copy is
            // unpublished and must not block a later retry of the same mod.
            try? library.removeItem(at: destination)
            throw error
        }
    }

    static func payloadDirectory(for manifest: ModPackageManifest) throws -> SafeRelativePath? {
        let payload = try SafeRelativePath(manifest.payloadPath)
        let components = Array(payload.components.dropLast())
        return components.isEmpty ? nil : try SafeRelativePath(components.joined(separator: "/"))
    }

    static func copyPackage(manifest: ModPackageManifest, layout: ModSupportLayout,
        fs: ContainedFileSystem, sessionPath: SafeRelativePath) throws {
        let version = manifest.version
        let sourceFS = try ContainedFileSystem(root: layout.versions)
        let versionPath = try SafeRelativePath(version)
        _ = try ModSupportFileSystem.copyContents(from: sourceFS, sourceDirectory: versionPath,
            to: fs, destinationDirectory: sessionPath, validateModContent: false, limit: .package)
        let scan = try ModSupportFileSystem.scanTree(fs, root: sessionPath, validateModContent: false,
            limit: .package)
        let declared = Set(manifest.files.map(\.path))
        guard declared == Set(scan.files.keys),
            impliedDirectories(declared) == scan.directories else {
            throw LauncherError.io("The installed mod package has changed")
        }
        for file in manifest.files {
            let path = try SafeRelativePath(sessionPath.description + "/" + file.path)
            guard scan.files[file.path] == file.size else {
                throw LauncherError.sizeMismatch(path: file.path, expected: file.size,
                    actual: scan.files[file.path] ?? -1)
            }
            let digest = try ModSupportFileSystem.digest(fs, at: path)
            let expected = try Digest(algorithm: .sha256, hex: file.sha256)
            guard digest == expected else {
                throw LauncherError.digestMismatch(path: file.path, expected: file.sha256, actual: digest.hex)
            }
        }
    }

    static func copyEnabledMods(state: ModSupportState, library: ContainedFileSystem,
        fs: ContainedFileSystem, modsPath: SafeRelativePath) throws {
        try fs.createDirectory(at: modsPath)
        for mod in state.mods where mod.enabled {
            let sourcePath = try SafeRelativePath(mod.folderPath)
            guard try library.itemType(at: sourcePath) == .directory else {
                throw LauncherError.io("An enabled mod is missing")
            }
            let destination = try SafeRelativePath(modsPath.description + "/" + mod.id)
            let scan = try ModSupportFileSystem.copyContents(from: library, sourceDirectory: sourcePath,
                to: fs, destinationDirectory: destination, validateModContent: true, limit: .mod)
            guard scan.iniCount > 0 else { throw LauncherError.io("An enabled mod contains no INI file") }
        }
    }

    static func configureD3DX(fs: ContainedFileSystem, sessionPath: SafeRelativePath,
        payloadDirectory: SafeRelativePath?, backend: String) throws {
        let prefix = payloadDirectory.map { $0.description + "/" } ?? ""
        let path = try SafeRelativePath(sessionPath.description + "/" + prefix + "d3dx.ini")
        var contents: String?
        if let type = try fs.itemType(at: path) {
            guard type == .regularFile else { throw LauncherError.unsafePath(path.description) }
            let data = try fs.readFile(at: path, maxBytes: ModSupportConstants.maximumSettingsTextBytes)
            guard let text = String(data: data, encoding: .utf8) else {
                throw LauncherError.io("d3dx.ini is not UTF-8")
            }
            contents = text
        }
        var ini = D3DXIni(contents)
        try ini.set(section: "Loader", key: "target", value: ModSupportConstants.runnerTarget)
        try ini.set(section: "Loader", key: "loader", value: "hook-runner.exe")
        try ini.set(section: "System", key: "proxy_d3d11", value: backend)
        try ini.addIfMissing(section: "Include", key: "include_recursive", value: "Mods")
        guard let data = ini.rendered().data(using: .utf8) else {
            throw LauncherError.io("Cannot encode d3dx.ini")
        }
        try fs.writeAtomically(data, to: path)
    }

    static func impliedDirectories(_ files: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for file in files {
            let components = file.split(separator: "/")
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                result.insert(components.prefix(count).joined(separator: "/"))
            }
        }
        return result
    }

    static func sessionFile(_ relative: String, sessionPath: SafeRelativePath) throws -> SafeRelativePath {
        try SafeRelativePath(sessionPath.description + "/" + relative)
    }
}
