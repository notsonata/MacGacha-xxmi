// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

struct ModTreeScan {
    var files: [String: Int64] = [:]
    var directories: Set<String> = []
    var iniCount = 0
    var totalBytes: Int64 = 0
    var entries = 0
}

enum ModSupportFileSystem {
    private static let executableExtensions: Set<String> = [
        "app", "bat", "cmd", "com", "command", "cpl", "dll", "drv", "dylib", "exe",
        "msi", "ocx", "pif", "ps1", "psm1", "scr", "sh", "so", "sys",
    ]

    static func digest(_ fs: ContainedFileSystem, at path: SafeRelativePath) throws -> Digest {
        var hasher = StreamingHasher(.sha256)
        try fs.readFile(at: path) { hasher.update($0) }
        return hasher.finalize()
    }

    static func scanTree(_ fs: ContainedFileSystem, root: SafeRelativePath, validateModContent: Bool,
        limit: ModSupportConstants.Limits = .package) throws -> ModTreeScan {
        var scan = ModTreeScan()
        try walk(fs, directory: root, root: root, depth: 0, validateModContent: validateModContent,
            scan: &scan, limit: limit)
        return scan
    }

    static func copyContents(from source: ContainedFileSystem, sourceDirectory: SafeRelativePath,
        to destination: ContainedFileSystem, destinationDirectory: SafeRelativePath,
        validateModContent: Bool, limit: ModSupportConstants.Limits = .mod,
        afterSourceValidation: ((ContainedFileSystem, SafeRelativePath) throws -> Void)? = nil) throws -> ModTreeScan {
        var scan = ModTreeScan()
        try copyDirectory(source, sourceDirectory, sourceDirectory, destination, destinationDirectory, depth: 0,
            validateModContent: validateModContent, scan: &scan, limit: limit,
            afterSourceValidation: afterSourceValidation)
        return scan
    }

    private static func walk(_ fs: ContainedFileSystem, directory: SafeRelativePath, root: SafeRelativePath,
        depth: Int, validateModContent: Bool, scan: inout ModTreeScan, limit: ModSupportConstants.Limits) throws {
        guard depth <= ModSupportConstants.maximumModDepth else { throw LauncherError.io("Mod directory is too deep") }
        for path in try fs.contentsOfDirectory(at: directory) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            scan.entries += 1
            guard scan.entries <= limit.entries else { throw LauncherError.io("Mod tree has too many entries") }
            guard let type = try fs.itemType(at: path, allowingLeafSymlink: true) else { continue }
            switch type {
            case .directory:
                scan.directories.insert(try relativePath(path, under: root))
                try walk(fs, directory: path, root: root, depth: depth + 1,
                    validateModContent: validateModContent, scan: &scan, limit: limit)
            case .regularFile:
                let name = path.components.last!
                if validateModContent { try validateRegularModFile(fs, path: path) }
                guard let size = try fs.size(at: path), size >= 0 else {
                    throw LauncherError.io("Mod file size is invalid")
                }
                let relative = try relativePath(path, under: root)
                let (sum, overflow) = scan.totalBytes.addingReportingOverflow(size)
                guard !overflow, sum <= limit.bytes else {
                    throw LauncherError.fileTooLarge(path: "mod tree", limit: Int(clamping: limit.bytes))
                }
                scan.totalBytes = sum
                scan.files[relative] = size
                if validateModContent, name.lowercased().hasSuffix(".ini") { scan.iniCount += 1 }
            case .other:
                throw LauncherError.unsafePath(path.description)
            }
        }
    }

    private static func copyDirectory(_ source: ContainedFileSystem, _ sourceDirectory: SafeRelativePath,
        _ sourceRoot: SafeRelativePath, _ destination: ContainedFileSystem, _ destinationDirectory: SafeRelativePath,
        depth: Int, validateModContent: Bool, scan: inout ModTreeScan, limit: ModSupportConstants.Limits,
        afterSourceValidation: ((ContainedFileSystem, SafeRelativePath) throws -> Void)?) throws {
        guard depth <= ModSupportConstants.maximumModDepth else { throw LauncherError.io("Mod directory is too deep") }
        try destination.createDirectory(at: destinationDirectory)
        for path in try source.contentsOfDirectory(at: sourceDirectory) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            scan.entries += 1
            guard scan.entries <= limit.entries else { throw LauncherError.io("Mod tree has too many entries") }
            let name = path.components.last!
            let target = try SafeRelativePath(destinationDirectory.description + "/" + name)
            switch try source.itemType(at: path, allowingLeafSymlink: true) {
            case .directory:
                try copyDirectory(source, path, sourceRoot, destination, target, depth: depth + 1,
                    validateModContent: validateModContent, scan: &scan, limit: limit,
                    afterSourceValidation: afterSourceValidation)
            case .regularFile:
                guard let size = try source.size(at: path), size >= 0 else {
                    throw LauncherError.io("Mod file size is invalid")
                }
                let (sum, overflow) = scan.totalBytes.addingReportingOverflow(size)
                guard !overflow, sum <= limit.bytes else {
                    throw LauncherError.fileTooLarge(path: "mod tree", limit: Int(clamping: limit.bytes))
                }
                if validateModContent { try validateRegularModFile(source, path: path) }
                try afterSourceValidation?(source, path)
                try copyFile(source, path, destination, target, size: size)
                // The source path is reopened for the copy, so validate the retained
                // target bytes instead of trusting the earlier source check.
                if validateModContent { try validateRegularModFile(destination, path: target) }
                scan.totalBytes = sum
                scan.files[try relativePath(path, under: sourceRoot)] = size
                if validateModContent, name.lowercased().hasSuffix(".ini") { scan.iniCount += 1 }
            case .other:
                throw LauncherError.unsafePath(path.description)
            case .none:
                throw LauncherError.io("Mod source changed during import")
            }
        }
    }

    private static func copyFile(_ source: ContainedFileSystem, _ sourcePath: SafeRelativePath,
        _ destination: ContainedFileSystem, _ destinationPath: SafeRelativePath, size: Int64) throws {
        let input = try source.openForReading(at: sourcePath)
        defer { try? input.close() }
        let output = try destination.openForWriting(at: destinationPath, truncate: true)
        defer { try? output.close() }
        var copied: Int64 = 0
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let data = try autoreleasepool { try input.read(upToCount: 65_536) ?? Data() }
            if data.isEmpty { break }
            let (sum, overflow) = copied.addingReportingOverflow(Int64(data.count))
            guard !overflow, sum <= size else { throw LauncherError.io("Mod source changed during import") }
            try output.write(contentsOf: data)
            copied = sum
        }
        guard copied == size else { throw LauncherError.io("Mod source changed during import") }
    }

    private static func validateRegularModFile(_ fs: ContainedFileSystem, path: SafeRelativePath) throws {
        let name = path.components.last!
        let ext = (name as NSString).pathExtension.lowercased()
        guard !executableExtensions.contains(ext) else {
            throw LauncherError.io("Mods cannot contain executables")
        }
        let input = try fs.openForReading(at: path)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 4) ?? Data()
        let bytes = Array(prefix)
        guard !looksExecutable(bytes) else { throw LauncherError.io("Mods cannot contain executables") }
    }

    private static func looksExecutable(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        if bytes[0] == 0x4D, bytes[1] == 0x5A { return true } // PE
        guard bytes.count >= 4 else { return false }
        let magic = [UInt8](bytes.prefix(4))
        if magic == [0x7F, 0x45, 0x4C, 0x46] { return true } // ELF
        return magic == [0xFE, 0xED, 0xFA, 0xCE] || magic == [0xCE, 0xFA, 0xED, 0xFE]
            || magic == [0xFE, 0xED, 0xFA, 0xCF] || magic == [0xCF, 0xFA, 0xED, 0xFE]
            || magic == [0xCA, 0xFE, 0xBA, 0xBE]
    }

    private static func relativePath(_ path: SafeRelativePath, under directory: SafeRelativePath) throws -> String {
        let prefix = directory.description + "/"
        guard path.description.hasPrefix(prefix) else { throw LauncherError.unsafePath(path.description) }
        return String(path.description.dropFirst(prefix.count))
    }
}

extension ModSupportConstants {
    struct Limits: Sendable {
        let entries: Int
        let bytes: Int64

        static let package = Limits(entries: ModPackageManifest.maximumFileCount,
            bytes: ModPackageManifest.maximumExpandedBytes)
        static let mod = Limits(entries: maximumModFiles, bytes: maximumModBytes)
        /// A whole managed library can hold many imported mods. Relocation still
        /// bounds entries and bytes so a hostile tree cannot exhaust the copy.
        static let library = Limits(entries: maximumModFiles * 20, bytes: maximumModBytes * 512)
    }
}
