// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

public enum NativeProxyRestoreOutcome: Equatable, Sendable {
    /// Every owned entry is resolved and `persist(nil)` succeeded.
    case clean
    /// Something at an owned or expected name is not ours. Those items and any
    /// hidden originals are retained; the record stays owned for a later retry.
    case conflict(retained: [String])
    /// An I/O, journal or validation failure. The record stays owned; retry later.
    case pending(reason: String)
}

/// Write-ahead file transaction for ZZZ's native D3D11 proxy in one prefix's system32.
///
/// Contract for the launch layer (synchronous I/O; run through BlockingIO.run while
/// holding session/prefix ownership, with no Wine process using the prefix):
///
/// * `place` requires `record == nil`. Preflight is read-only and throws
///   `NativeProxyError.preflight` with zero changes on any conflict. It then calls
///   `persist` with the full plan before the first mutation and again after every
///   mutation. `record` is updated before each `persist` call, so the in-memory
///   value is always at least as new as the durable one. Any later throw leaves
///   `record` non-nil: the caller keeps it durable and calls `restore`.
/// * `persist` must durably write (or, for `nil`, durably clear) the record
///   before returning, and throw if it cannot. It is invoked synchronously.
/// * `restore` is called only after verified process end. It is idempotent and
///   location-driven, so it is correct with either the newest or the previous
///   persisted record after a crash. It never throws: `.clean` means `record`
///   is now nil and was durably cleared; otherwise `record` is retained.
/// * The caller validates `sessionDirectory` under the actual sessions path.
///   Its payload must contain `d3d11.dll`, `d3dcompiler_47.dll`, `d3dx.ini`
///   (regular files) and `Core`, `Mods` (directories).
/// * Callers that harvest runtime logs do so before `restore`, which removes the
///   regular single-link files named in `NativeProxyRecord.prospectiveOutputNames`.
public struct NativeProxyFiles: Sendable {
    public typealias Persist = (NativeProxyRecord?) throws -> Void
    private static let maximumPayloadBytes: Int64 = 512 << 20

    private let fileOps: any FileOps
    private let hook: @Sendable (NativeProxyFileStep) throws -> Void

    public init() { self.init(fileOps: SystemFileOps()) }
    /// `hook` throwing at a step models process death at that boundary.
    package init(fileOps: any FileOps = SystemFileOps(), hook: @escaping @Sendable (NativeProxyFileStep) throws -> Void = { _ in }) {
        self.fileOps = fileOps; self.hook = hook
    }

    // MARK: Place

    public func place(sessionDirectory: URL, prefix: URL, sessionID: UUID,
        record: inout NativeProxyRecord?, persist: Persist) throws {
        guard record == nil else { throw NativeProxyError.busy }
        let plan = try preflight(sessionDirectory: sessionDirectory, prefix: prefix, sessionID: sessionID)
        var current = plan.record
        func commit(_ step: NativeProxyFileStep) throws {
            record = current
            try persist(current)
            try hook(step)
        }
        try commit(.afterPlanPersist)
        let system32 = plan.system32, session = plan.session

        // The private removal area comes first, so every later mutation has a
        // recorded place where owned entries are claimed before unlinking.
        let areaName = NativeProxyRecord.removalAreaName(sessionID: sessionID)
        try system32.withRootDirectoryDescriptor { fd in
            guard mkdirat(fd, areaName, 0o700) == 0 else {
                throw LauncherError.fileSystemFailure("Cannot create the native proxy removal area", code: errno)
            }
            try system32.fileOps.synchronize(fd, durable: false)
        }
        guard let area = try system32.pinDirectoryIfPresent(at: path(areaName)),
            let areaIdentity = try Self.privateDirectoryIdentity(of: area) else {
            throw LauncherError.io("The native proxy removal area changed after creation")
        }
        current.removalArea = areaIdentity
        record = current
        try hook(.afterAreaCreate)
        try commit(.afterAreaPersist)

        for index in current.originals.indices {
            let entry = current.originals[index]
            try hook(.beforeHideRename)
            try system32.withClaimedFile(at: path(entry.name)) { claim in
                guard claim.stamp.sameContentMetadata(as: entry.original.stamp), claim.sha256 == entry.original.sha256,
                    try claim.ownedIdentity() == entry.original.identity else {
                    throw LauncherError.io("A system32 original changed before hiding")
                }
                guard try claim.move(to: path(entry.hiddenName), in: system32) else {
                    throw LauncherError.io("A hidden system32 original could not be verified")
                }
            }
            try hook(.afterHideRename)
            current.originals[index].state = .hidden
            try commit(.afterHidePersist)
        }

        for index in current.files.indices {
            let entry = current.files[index]
            try hook(.beforeStageCreate)
            guard let owned = try system32.createOwnedFile(at: path(entry.stageName)) else {
                throw LauncherError.io("A native proxy stage name is already in use")
            }
            // In memory at once; durable at the next commit. Death in between
            // leaves an unrecorded stage that restore retains rather than deletes.
            current.files[index].identity = owned.identity
            current.files[index].state = .staged
            record = current
            try hook(.afterStageCreate)
            try commit(.afterStagePersist)
            // A hard-linked source is shared with an unknown name: refuse it.
            try session.withClaimedFile(at: entry.sourcePath, maximumBytes: Self.maximumPayloadBytes) { source in
                guard source.stamp.size == entry.size, source.sha256 == entry.sha256 else {
                    throw LauncherError.io("A session payload file changed")
                }
                try source.copyBytes(to: owned)
            }
            try owned.fullSync()
            try hook(.beforePublish)
            try owned.withClaim { staged in
                guard staged.stamp.size == entry.size, staged.sha256 == entry.sha256 else {
                    throw LauncherError.io("A staged native proxy file does not match its payload")
                }
                guard try staged.move(to: path(entry.name), in: system32) else {
                    throw LauncherError.io("A placed native proxy file could not be verified")
                }
            }
            try hook(.afterPublish)
            current.files[index].state = .placed
            try commit(.afterPlacePersist)
        }

        for index in current.links.indices {
            let entry = current.links[index]
            try hook(.beforeLinkCreate)
            try system32.createSymbolicLink(at: path(entry.name), target: entry.target)
            guard let stamp = try system32.entryStamp(at: path(entry.name)), stamp.kind == UInt32(S_IFLNK) else {
                throw LauncherError.io("A native proxy link changed after creation")
            }
            current.links[index].stamp = stamp
            current.links[index].state = .linked
            record = current
            try hook(.afterLinkCreate)
            try commit(.afterLinkPersist)
        }
        current.phase = .placed
        try commit(.afterPlacedPersist)
    }

    // MARK: Restore

    public func restore(prefix: URL, sessionID: UUID, record: inout NativeProxyRecord?, persist: Persist) -> NativeProxyRestoreOutcome {
        guard var current = record else { return .clean }
        do { try current.validate(prefix: prefix, sessionID: sessionID) }
        catch { return .pending(reason: "\(error)") }
        let system32: ContainedFileSystem
        do {
            let prefixFS = try ContainedFileSystem(root: current.prefix, fileOps: fileOps,
                expectedRootIdentity: current.prefixIdentity).pinRoot()
            guard let pinned = try prefixFS.pinDirectoryIfPresent(at: path(NativeProxyRecord.system32Path)) else {
                return .conflict(retained: ["system32"])
            }
            guard try pinned.rootIdentity() == current.system32Identity else { return .conflict(retained: ["system32"]) }
            system32 = pinned
        } catch LauncherError.io(let message) where message == "install folder was replaced" {
            return .conflict(retained: ["prefix"])
        } catch {
            return .pending(reason: "\(error)")
        }

        var conflicts: [String] = []
        do {
            func commit(_ step: NativeProxyFileStep) throws {
                record = current
                try persist(current)
                try hook(step)
            }
            if current.phase != .restoring {
                current.phase = .restoring
                try commit(.afterRestoringPersist)
            }
            let area = try openArea(current, in: system32)
            if case .unavailable(let item) = area { conflicts.append(item) }
            // Journal flags do not replace reconciling the actual owned names.
            for index in current.links.indices.reversed() {
                switch try removeLink(current.links[index], area: area, in: system32) {
                case .resolved:
                    try hook(.afterLinkRemove)
                    current.links[index].state = .removed
                    try commit(.afterRestoreEntryPersist)
                case .conflict(let item): conflicts.append(item)
                }
            }
            for index in current.files.indices.reversed() {
                let name = current.files[index].name
                let originalPrint = current.originals.first(where: { $0.name == name })?.original
                switch try removePlaced(current.files[index], original: originalPrint, area: area, in: system32) {
                case .resolved:
                    try hook(.afterFileRemove)
                    current.files[index].state = .removed
                    try commit(.afterRestoreEntryPersist)
                case .conflict(let item): conflicts.append(item)
                }
                guard let original = current.originals.firstIndex(where: { $0.name == name }) else { continue }
                // An original returns only to a name we have vacated ourselves.
                guard current.files[index].state == .removed else {
                    conflicts.append(current.originals[original].hiddenName); continue
                }
                switch try restoreOriginal(current.originals[original], in: system32) {
                case .resolved:
                    try hook(.afterOriginalRestore)
                    current.originals[original].state = .restored
                    try commit(.afterRestoreEntryPersist)
                case .conflict(let item): conflicts.append(item)
                }
            }
            for name in NativeProxyRecord.prospectiveOutputNames {
                if case .conflict(let item) = try removeOutput(name, area: area, in: system32) { conflicts.append(item) }
            }
            guard conflicts.isEmpty, current.allResolved else {
                return .conflict(retained: conflicts.isEmpty ? ["incomplete"] : conflicts)
            }
            // Clean only once nothing remains in the private area.
            if case .owned(let areaFS, let areaName) = area {
                let leftover = try removeArea(areaFS, named: areaName, record: current, in: system32)
                guard leftover.isEmpty else { return .conflict(retained: leftover) }
                try hook(.afterAreaRemove)
            }
            try hook(.beforeClear)
            try persist(nil)
            record = nil
            return .clean
        } catch {
            return .pending(reason: "Native proxy files could not be fully restored: \(error)")
        }
    }

    // MARK: Preflight (read-only)

    private struct Plan {
        let record: NativeProxyRecord
        let system32: ContainedFileSystem
        let session: ContainedFileSystem
    }

    private func preflight(sessionDirectory: URL, prefix: URL, sessionID: UUID) throws -> Plan {
        func reject(_ reason: String) -> NativeProxyError { .preflight(reason) }
        guard NativeProxyRecord.isCanonicalDirectory(prefix), NativeProxyRecord.isCanonicalDirectory(sessionDirectory) else {
            throw reject("Prefix and session paths must be absolute and standardized")
        }
        let prefixFS = try ContainedFileSystem(root: prefix, fileOps: fileOps).pinRoot()
        let sessionFS = try ContainedFileSystem(root: sessionDirectory, fileOps: fileOps).pinRoot()
        let system32Path = try path(NativeProxyRecord.system32Path)
        let pinned: ContainedFileSystem?
        do { pinned = try prefixFS.pinDirectoryIfPresent(at: system32Path) }
        catch LauncherError.unsafePath(_) { throw reject("system32 or one of its parents is not a real directory") }
        guard let system32 = pinned else { throw reject("The prefix has no system32 directory") }

        // Case-folded scan: a foreign or orphaned entry that Wine could resolve
        // to one of our names, or any earlier transaction name, fails closed.
        let fold = { (name: String) in name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
        let reserved = Set((["d3dx.ini"] + NativeProxyRecord.linkNames + NativeProxyRecord.prospectiveOutputNames).map(fold))
        let dlls = Set(NativeProxyRecord.dllNames.map(fold))
        let listing = try system32.contentsOfRootDirectoryReportingInvalid()
        for entry in listing.paths {
            let name = entry.components.last!, folded = fold(name)
            if folded.hasPrefix(".macgacha-") || folded.contains(".macgacha-hidden") {
                throw reject("An unfinished native proxy or hidden-file transaction is present in system32")
            }
            if reserved.contains(folded) { throw reject("system32 already contains \(name)") }
            if dlls.contains(folded), !NativeProxyRecord.dllNames.contains(name) {
                throw reject("system32 contains a differently cased \(name)")
            }
        }

        var originals: [NativeProxyRecord.HiddenOriginal] = []
        for name in NativeProxyRecord.dllNames {
            guard let stamp = try system32.entryStamp(at: path(name)) else {
                throw reject("system32 \(name) is missing; the native proxy baseline is incomplete")
            }
            guard stamp.kind == UInt32(S_IFREG) else { throw reject("system32 \(name) is not a regular file") }
            guard stamp.links == 1 else { throw reject("system32 \(name) is hard-linked") }
            let print = try system32.withClaimedFile(at: path(name), maximumBytes: Self.maximumPayloadBytes) { claim in
                NativeProxyRecord.Fingerprint(size: claim.stamp.size, sha256: claim.sha256, stamp: claim.stamp,
                    identity: try claim.ownedIdentity())
            }
            originals.append(.init(name: name, hiddenName: NativeProxyRecord.hiddenName(name, sessionID: sessionID),
                original: print, state: .planned))
        }

        var files: [NativeProxyRecord.PlacedFile] = []
        for name in NativeProxyRecord.fileNames {
            let source = try path(NativeProxyRecord.payloadDirectory + "/" + name)
            guard let stamp = try sessionFS.entryStamp(at: source) else { throw reject("Session payload \(name) is missing") }
            guard stamp.kind == UInt32(S_IFREG), stamp.links == 1 else {
                throw reject("Session payload \(name) is not a regular single-link file")
            }
            let (size, sha) = try sessionFS.withClaimedFile(at: source,
                maximumBytes: Self.maximumPayloadBytes) { ($0.stamp.size, $0.sha256) }
            files.append(.init(name: name, stageName: NativeProxyRecord.stageName(name, sessionID: sessionID),
                sourcePath: source, size: size, sha256: sha, identity: nil, state: .planned))
        }
        var links: [NativeProxyRecord.PlacedLink] = []
        for name in NativeProxyRecord.linkNames {
            guard try sessionFS.itemType(at: path(NativeProxyRecord.payloadDirectory + "/" + name), allowingLeafSymlink: true) == .directory else {
                throw reject("Session payload \(name) is not a directory")
            }
            links.append(.init(name: name, target: NativeProxyRecord.linkTarget(name, sessionDirectory: sessionDirectory),
                stamp: nil, state: .planned))
        }
        let record = NativeProxyRecord(version: NativeProxyRecord.currentVersion, sessionID: sessionID,
            prefix: prefix, sessionDirectory: sessionDirectory, prefixIdentity: try prefixFS.rootIdentity(),
            system32Identity: try system32.rootIdentity(), phase: .placing,
            originals: originals, files: files, links: links)
        try record.validate(prefix: prefix, sessionID: sessionID)
        return Plan(record: record, system32: system32, session: sessionFS)
    }

    // MARK: Restore steps

    private enum Resolution { case resolved, conflict(String) }

    /// Where owned entries are claimed before unlinking. `owned` is the recorded,
    /// owner-only directory; nothing is ever unlinked from a public name.
    private enum Area {
        /// Not recorded and absent: nothing beyond the plan was mutated.
        case notCreated
        /// Recorded but absent (removed just before a crash, or by someone else).
        case vanished
        /// Present but unrecorded, foreign or not owner-only: retained untouched.
        case unavailable(String)
        case owned(ContainedFileSystem, name: String)
    }

    /// Recognizes an owned object by a no-follow stat of `name` in `directory`.
    private typealias Ownership = (_ info: stat, _ directory: Int32, _ name: String) -> Bool

    private static func privateDirectoryIdentity(of fs: ContainedFileSystem) throws -> NativeProxyRecord.DirectoryIdentity? {
        try fs.withRootDirectoryDescriptor { fd in
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw LauncherError.io("Cannot inspect the native proxy removal area") }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { return nil }
            return NativeProxyRecord.DirectoryIdentity(info)
        }
    }

    private func openArea(_ record: NativeProxyRecord, in system32: ContainedFileSystem) throws -> Area {
        let name = NativeProxyRecord.removalAreaName(sessionID: record.sessionID)
        guard let stamp = try system32.entryStamp(at: path(name)) else {
            return record.removalArea == nil ? .notCreated : .vanished
        }
        // A reserved name is not ownership: an unrecorded area is never adopted.
        guard let expected = record.removalArea, stamp.kind == UInt32(S_IFDIR) else { return .unavailable(name) }
        let pinned: ContainedFileSystem?
        do { pinned = try system32.pinDirectoryIfPresent(at: path(name)) }
        catch LauncherError.unsafePath(_) { return .unavailable(name) }
        guard let pinned, try Self.privateDirectoryIdentity(of: pinned) == expected else { return .unavailable(name) }
        return .owned(pinned, name: name)
    }

    /// Claim-then-unlink. Any leftover at `key` from an interrupted removal is
    /// settled first. The public entry is renamed exclusively into the private
    /// area only when it looks owned, then re-identified there; only a verified
    /// owned inode is unlinked. Anything else is returned to its vacant public
    /// name or kept in the area, and ownership is retained.
    private func remove(_ name: String, key: String, area: Area, in system32: ContainedFileSystem,
        isOwned: Ownership, keepPublic: (ContainedFileSystem.ClaimStamp) -> Bool = { _ in false }) throws -> Resolution {
        if case .owned(let areaFS, let areaName) = area, case .conflict(let item) = try settle(key, publicName: name,
            area: areaFS, areaName: areaName, in: system32, isOwned: isOwned) {
            return .conflict(item)
        }
        let publicPath = try path(name)
        guard let stamp = try system32.entryStamp(at: publicPath) else { return .resolved }
        if keepPublic(stamp) { return .resolved }
        let looksOwned = try system32.withRootDirectoryDescriptor { fd -> Bool in
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            return Int64(info.st_dev) == stamp.device && UInt64(info.st_ino) == stamp.inode && isOwned(info, fd, name)
        }
        guard looksOwned, case .owned(let areaFS, let areaName) = area else { return .conflict(name) }
        guard try system32.quarantineEntry(at: publicPath, to: path(key), in: areaFS, matching: stamp, didMove: { _ in }) else {
            return .conflict(name)
        }
        try hook(.afterQuarantine)
        return try settle(key, publicName: name, area: areaFS, areaName: areaName, in: system32, isOwned: isOwned)
    }

    /// Unlinks `key` from the pinned private area only if it is a verified owned
    /// object. A foreign object is handed back exclusively, never deleted.
    private func settle(_ key: String, publicName: String, area: ContainedFileSystem, areaName: String, in system32: ContainedFileSystem,
        isOwned: Ownership) throws -> Resolution {
        let removed: Bool? = try area.withRootDirectoryDescriptor { fd in
            var info = stat()
            guard fstatat(fd, key, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw LauncherError.io("Cannot inspect the native proxy removal area")
            }
            guard isOwned(info, fd, key) else { return false }
            try area.fileOps.unlink(key, in: fd, isDirectory: false)
            try area.fileOps.synchronize(fd, durable: false)
            return true
        }
        guard removed == false else { return .resolved }
        let keyPath = try path(key)
        let display = areaName + "/" + key
        guard let stamp = try area.entryStamp(at: keyPath) else { return .conflict(publicName) }
        let returned = (try? area.quarantineEntry(at: keyPath, to: path(publicName), in: system32, matching: stamp, didMove: { _ in })) ?? false
        return .conflict(returned ? publicName : display)
    }

    private static func isOwnedFile(_ identity: ContainedFileSystem.OwnedFileIdentity) -> Ownership {
        { info, _, _ in
            info.st_mode & S_IFMT == S_IFREG && Int64(info.st_dev) == identity.device && UInt64(info.st_ino) == identity.inode
                && Int64(info.st_birthtimespec.tv_sec) == identity.birthSeconds
                && Int64(info.st_birthtimespec.tv_nsec) == identity.birthNanos
        }
    }

    /// Our exact target (read, never followed) and, once recorded, our inode.
    private static func isOwnedLink(_ entry: NativeProxyRecord.PlacedLink) -> Ownership {
        { info, fd, name in
            guard info.st_mode & S_IFMT == S_IFLNK else { return false }
            if let stamp = entry.stamp, stamp.device != Int64(info.st_dev) || stamp.inode != UInt64(info.st_ino) { return false }
            var buffer = [CChar](repeating: 0, count: 4097)
            let count = readlinkat(fd, name, &buffer, buffer.count - 1)
            guard count >= 0 else { return false }
            return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self) == entry.target
        }
    }

    private func removeLink(_ entry: NativeProxyRecord.PlacedLink, area: Area, in system32: ContainedFileSystem) throws -> Resolution {
        try remove(entry.name, key: "link-" + entry.name, area: area, in: system32, isOwned: Self.isOwnedLink(entry))
    }

    /// Removes the stage and published names only when they hold our recorded
    /// inode. Without a durable identity nothing there is provably ours: an
    /// unrecorded stage (death after create, before persist) is retained.
    /// A final name still holding the recorded original inode (never hidden, or
    /// already restored) has no placed copy; the original step verifies its bytes.
    private func removePlaced(_ entry: NativeProxyRecord.PlacedFile, original: NativeProxyRecord.Fingerprint?,
        area: Area, in system32: ContainedFileSystem) throws -> Resolution {
        let stageKey = "stage-" + entry.name, fileKey = "file-" + entry.name
        let isOriginal = { (stamp: ContainedFileSystem.ClaimStamp) in original.map { stamp.sameObject(as: $0.stamp) } ?? false }
        guard let identity = entry.identity else {
            if try system32.entryStamp(at: path(entry.stageName)) != nil { return .conflict(entry.stageName) }
            if case .owned(let areaFS, let areaName) = area {
                for key in [stageKey, fileKey] where try areaFS.entryStamp(at: path(key)) != nil {
                    return .conflict(areaName + "/" + key)
                }
            }
            guard let final = try system32.entryStamp(at: path(entry.name)), !isOriginal(final) else { return .resolved }
            return .conflict(entry.name)
        }
        let owned = Self.isOwnedFile(identity)
        if case .conflict(let item) = try remove(entry.stageName, key: stageKey, area: area, in: system32, isOwned: owned) {
            return .conflict(item)
        }
        return try remove(entry.name, key: fileKey, area: area, in: system32, isOwned: owned, keepPublic: isOriginal)
    }

    /// Returns the recorded original into its vacant name, then verifies by rehash.
    private func restoreOriginal(_ entry: NativeProxyRecord.HiddenOriginal, in system32: ContainedFileSystem) throws -> Resolution {
        let hidden = try path(entry.hiddenName), original = try path(entry.name)
        func matches(_ claim: borrowing ContainedFileSystem.RegularFileClaim) throws -> Bool {
            try claim.stamp.sameContentMetadata(as: entry.original.stamp) && claim.sha256 == entry.original.sha256
                && claim.stamp.links == 1 && claim.ownedIdentity() == entry.original.identity
        }
        guard let hiddenStamp = try system32.entryStamp(at: hidden) else {
            // Crash after the restoring rename (or before hiding): verify in place.
            guard let stamp = try system32.entryStamp(at: original), stamp.kind == UInt32(S_IFREG) else {
                return .conflict(entry.name)
            }
            let ok = try system32.withClaimedFile(at: original, permitHardLinks: true) { try matches($0) }
            guard ok else { return .conflict(entry.name) }
            try system32.synchronizeAncestors(of: original)
            return .resolved
        }
        guard hiddenStamp.kind == UInt32(S_IFREG), try system32.entryStamp(at: original) == nil else {
            return .conflict(entry.hiddenName)
        }
        return try system32.withClaimedFile(at: hidden, permitHardLinks: true) { claim in
            guard try matches(claim) else { return .conflict(entry.hiddenName) }
            try hook(.beforeOriginalRestore)
            guard try claim.move(to: original, in: system32) else { return .conflict(entry.name) }
            return .resolved
        }
    }

    /// Runtime logs absent at placement: claim only regular single-link files.
    private func removeOutput(_ name: String, area: Area, in system32: ContainedFileSystem) throws -> Resolution {
        try remove(name, key: "output-" + name, area: area, in: system32,
            isOwned: { info, _, _ in info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 })
    }

    /// rmdir of the recorded area, only when empty and still the recorded inode.
    /// Returns what is retained; empty means the area is gone.
    private func removeArea(_ areaFS: ContainedFileSystem, named name: String, record: NativeProxyRecord,
        in system32: ContainedFileSystem) throws -> [String] {
        let leftover = try areaFS.contentsOfRootDirectoryReportingInvalid()
        let items = leftover.paths.map { name + "/" + $0.description } + leftover.invalid.map { name + "/" + $0 }
        guard items.isEmpty else { return items }
        return try system32.withRootDirectoryDescriptor { fd in
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return [] }
                throw LauncherError.io("Cannot inspect the native proxy removal area")
            }
            guard info.st_mode & S_IFMT == S_IFDIR, NativeProxyRecord.DirectoryIdentity(info) == record.removalArea else {
                return [name]
            }
            // rmdir: refuses a non-empty directory even if one raced in.
            try system32.fileOps.unlink(name, in: fd, isDirectory: true)
            try system32.fileOps.synchronize(fd, durable: false)
            return []
        }
    }

    private func path(_ raw: String) throws -> SafeRelativePath { try SafeRelativePath(raw) }
}

public enum NativeProxyError: Error, Equatable, Sendable {
    /// Read-only preflight refused; nothing was changed.
    case preflight(String)
    /// A record is already owned; restore it first.
    case busy
}

/// Explicit process-death seams for tests; no production environment switches.
package enum NativeProxyFileStep: String, Sendable, CaseIterable {
    case afterPlanPersist, afterAreaCreate, afterAreaPersist, beforeHideRename, afterHideRename, afterHidePersist
    case beforeStageCreate, afterStageCreate, afterStagePersist, beforePublish, afterPublish, afterPlacePersist
    case beforeLinkCreate, afterLinkCreate, afterLinkPersist, afterPlacedPersist
    case afterRestoringPersist, afterLinkRemove, afterFileRemove, beforeOriginalRestore, afterOriginalRestore
    case afterRestoreEntryPersist, afterQuarantine, afterAreaRemove, beforeClear
    package static let placeSteps: [Self] = [.afterPlanPersist, .afterAreaCreate, .afterAreaPersist, .beforeHideRename, .afterHideRename, .afterHidePersist,
        .beforeStageCreate, .afterStageCreate, .afterStagePersist, .beforePublish, .afterPublish, .afterPlacePersist,
        .beforeLinkCreate, .afterLinkCreate, .afterLinkPersist, .afterPlacedPersist]
    package static let restoreSteps: [Self] = [.afterRestoringPersist, .afterLinkRemove, .afterFileRemove,
        .beforeOriginalRestore, .afterOriginalRestore, .afterRestoreEntryPersist, .afterQuarantine, .afterAreaRemove, .beforeClear]
}
