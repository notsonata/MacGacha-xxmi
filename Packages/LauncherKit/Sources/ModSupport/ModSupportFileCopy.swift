// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

/// New mod files are exclusively created and copied through their retained descriptor.
/// Cloning remains disabled: fclonefileat cannot return the created inode's descriptor,
/// so reopening its destination cannot prove ownership before metadata mutation.
enum ModSupportFileCopy {
    static func copy(_ source: ContainedFileSystem, _ sourcePath: SafeRelativePath,
        _ destination: ContainedFileSystem, _ destinationPath: SafeRelativePath, size: Int64,
        preferClone: Bool, afterCopy: (() throws -> Void)?) throws {
        guard size >= 0 else { throw LauncherError.io("Mod source changed during import") }
        let input = try source.openForReading(at: sourcePath)
        defer { try? input.close() }
        var info = stat()
        guard fstat(input.fileDescriptor, &info) == 0, info.st_size == size else {
            throw LauncherError.io("Mod source changed during import")
        }
        func perform(_ parent: Int32) throws {
            let name = destinationPath.components.last!
            let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw LauncherError.fileSystemFailure("Cannot exclusively create mod file") }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? output.close() }
            var created = stat()
            guard fstat(descriptor, &created) == 0 else { throw LauncherError.io("Cannot inspect mod copy") }
            do {
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
                try afterCopy?()
                var current = stat(), held = stat()
                guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                    fstat(descriptor, &held) == 0, current.st_dev == created.st_dev,
                    current.st_ino == created.st_ino, held.st_nlink == 1, held.st_flags == 0,
                    held.st_size == size else { throw LauncherError.unsafePath(destinationPath.description) }
                // Source modes, flags, ACLs and attributes are never copied.
                guard fchmod(descriptor, 0o600) == 0 else {
                    throw LauncherError.fileSystemFailure("Cannot set mod file permissions")
                }
            } catch {
                var current = stat(), held = stat()
                if fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                    fstat(descriptor, &held) == 0, current.st_dev == created.st_dev,
                    current.st_ino == created.st_ino, held.st_nlink == 1, held.st_flags == 0 {
                    try? destination.fileOps.unlink(name, in: parent, isDirectory: false)
                }
                throw error
            }
        }
        let components = destinationPath.components.dropLast()
        if components.isEmpty { try destination.withRootDirectoryDescriptor(perform); return }
        let parent = try SafeRelativePath(components.joined(separator: "/"))
        try destination.createDirectory(at: parent)
        guard let pinned = try destination.pinDirectoryIfPresent(at: parent) else {
            throw LauncherError.io("Mod destination directory is missing")
        }
        try pinned.withRootDirectoryDescriptor(perform)
    }
}
