// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

/// Copies the fixed native-loader diagnostics out of a session's system32 into
/// the launcher log directory before `NativeProxyFiles.restore` removes them.
///
/// Only `NativeProxyRecord.prospectiveOutputNames` are considered. Placement
/// preflight proves those names were absent, so a regular file there after the
/// verified end was created by this session. Every failure is reported as a
/// result and never thrown: harvesting must not block file restoration.
/// Synchronous blocking I/O; call it from `BlockingIO.run`.
package struct NativeProxyLogHarvester: Sendable {
    package enum Status: Equatable, Sendable {
        /// Copied atomically; the byte count is the exported size.
        case exported(bytes: Int64)
        /// Nothing was written at the name. This is normal.
        case missing
        /// Larger than `maximumBytes`; left untouched and not exported.
        case tooLarge(bytes: Int64)
        /// Not a regular single-link file, or the pinned directories changed.
        case unsafe
        /// An I/O failure while reading or publishing.
        case failed
    }

    package struct Item: Equatable, Sendable {
        package let name: String
        /// Leaf name inside the launcher log directory; set only when exported.
        package let destination: String?
        package let status: Status
    }

    /// One runtime log is read into memory, so the cap is deliberately modest.
    package static let maximumBytes: Int64 = 16 << 20

    private let fileOps: any FileOps
    package init(fileOps: any FileOps = SystemFileOps()) { self.fileOps = fileOps }

    /// The session-correlated leaf name inside the log directory.
    package static func destinationName(stem: String, name: String) -> String { stem + "." + name }

    /// `stem` is the session log's leaf name without `.log`, so the exports sort
    /// beside, and are visibly tied to, the session log that names them.
    package func harvest(record: NativeProxyRecord, prefix: URL, sessionID: UUID, stem: String, logs: URL) -> [Item] {
        let names = NativeProxyRecord.prospectiveOutputNames
        func all(_ status: Status) -> [Item] { names.map { Item(name: $0, destination: nil, status: status) } }
        // The game never started if the files were not completely placed.
        guard record.phase != .placing else { return [] }
        do {
            try record.validate(prefix: prefix, sessionID: sessionID)
            let prefixFS = try ContainedFileSystem(root: record.prefix, fileOps: fileOps,
                expectedRootIdentity: record.prefixIdentity).pinRoot()
            guard let system32 = try prefixFS.pinDirectoryIfPresent(at: SafeRelativePath(NativeProxyRecord.system32Path)) else {
                return all(.missing)
            }
            guard try system32.rootIdentity() == record.system32Identity else { return all(.unsafe) }
            let logFS = try ContainedFileSystem(root: logs, fileOps: fileOps).pinRoot()
            return names.map { harvest($0, from: system32, to: logFS, stem: stem) }
        } catch LauncherError.unsafePath(_) {
            return all(.unsafe)
        } catch {
            return all(.failed)
        }
    }

    private func harvest(_ name: String, from system32: ContainedFileSystem, to logs: ContainedFileSystem, stem: String) -> Item {
        func item(_ status: Status, destination: String? = nil) -> Item { Item(name: name, destination: destination, status: status) }
        do {
            let source = try SafeRelativePath(name)
            guard let stamp = try system32.entryStamp(at: source) else { return item(.missing) }
            guard stamp.kind == UInt32(S_IFREG), stamp.links == 1 else { return item(.unsafe) }
            guard stamp.size <= Self.maximumBytes else { return item(.tooLarge(bytes: stamp.size)) }
            // No-follow, single-link and size-bounded again at open time.
            let data = try system32.withClaimedFile(at: source, maximumBytes: Self.maximumBytes) { claim in
                try claim.readData(maxBytes: Int(Self.maximumBytes))
            }
            let destination = Self.destinationName(stem: stem, name: name)
            try logs.writeAtomically(data, to: SafeRelativePath(destination))
            return item(.exported(bytes: Int64(data.count)), destination: destination)
        } catch LauncherError.unsafePath(_) {
            return item(.unsafe)
        } catch {
            return item(.failed)
        }
    }
}
