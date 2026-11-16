// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

/// Durable ownership of one session's native-proxy files in a prefix's system32.
/// Independent of LaunchSession: the launch layer stores it verbatim and hands it
/// back to `NativeProxyFiles`. Every name is derived from a fixed allowlist and
/// the session ID, so `validate` can reject any tampered entry before disk access.
public struct NativeProxyRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public enum Phase: String, Codable, Sendable { case placing, placed, restoring }

    /// A regular file observed without following links.
    package struct Fingerprint: Codable, Equatable, Sendable {
        package let size: Int64
        package let sha256: Digest
        package let stamp: ContainedFileSystem.ClaimStamp
        package let identity: ContainedFileSystem.OwnedFileIdentity
    }

    /// An original system32 DLL renamed in place to `hiddenName`.
    package struct HiddenOriginal: Codable, Equatable, Sendable {
        package enum State: String, Codable, Sendable { case planned, hidden, restored }
        package let name: String
        package let hiddenName: String
        package let original: Fingerprint
        package var state: State
    }

    /// A verified copy of a session payload file, staged under `stageName` and
    /// published exclusively at `name`. `identity` is known once staging begins.
    package struct PlacedFile: Codable, Equatable, Sendable {
        package enum State: String, Codable, Sendable { case planned, staged, placed, removed }
        package let name: String
        package let stageName: String
        package let sourcePath: SafeRelativePath
        package let size: Int64
        package let sha256: Digest
        package var identity: ContainedFileSystem.OwnedFileIdentity?
        package var state: State
    }

    /// A symlink at `name` whose exact absolute target is a session payload directory.
    package struct PlacedLink: Codable, Equatable, Sendable {
        package enum State: String, Codable, Sendable { case planned, linked, removed }
        package let name: String
        package let target: String
        package var stamp: ContainedFileSystem.ClaimStamp?
        package var state: State
    }

    /// The session's owner-only removal directory in system32. Birth time
    /// excludes reuse of a formerly owned inode.
    package struct DirectoryIdentity: Codable, Equatable, Sendable {
        package let device: Int64, inode: UInt64, birthSeconds: Int64, birthNanos: Int64
        package init(_ info: stat) {
            device = Int64(info.st_dev); inode = UInt64(info.st_ino)
            birthSeconds = Int64(info.st_birthtimespec.tv_sec); birthNanos = Int64(info.st_birthtimespec.tv_nsec)
        }
    }

    package let version: Int
    package let sessionID: UUID
    package let prefix: URL
    package let sessionDirectory: URL
    package let prefixIdentity: FileSystemIdentity
    package let system32Identity: FileSystemIdentity
    package var phase: Phase
    package var originals: [HiddenOriginal]
    package var files: [PlacedFile]
    package var links: [PlacedLink]
    /// Recorded immediately after the removal area is created, before any other
    /// mutation. Additive and optional in JSON: nil means not (provably) created.
    package var removalArea: DirectoryIdentity?

    // MARK: Fixed layout

    package static let system32Path = "drive_c/windows/system32"
    package static let dllNames = ["d3d11.dll", "d3dcompiler_47.dll"]
    package static let fileNames = dllNames + ["d3dx.ini"]
    package static let linkNames = ["Core", "Mods"]
    /// Runtime outputs absent at placement that 3DMigoto may create beside the DLL.
    /// User config and caches are redirected to M:, so only these are expected.
    public static let prospectiveOutputNames = ["d3d11_log.txt", "ShaderUsage.txt"]
    package static let payloadDirectory = "payload"

    package static func hiddenName(_ name: String, sessionID: UUID) -> String {
        name + ".macgacha-hidden-" + sessionID.uuidString
    }
    package static func stageName(_ name: String, sessionID: UUID) -> String {
        ".macgacha-native-" + sessionID.uuidString + "-" + name
    }
    /// Owner-only directory where owned entries are claimed and then unlinked.
    package static func removalAreaName(sessionID: UUID) -> String {
        ".macgacha-native-" + sessionID.uuidString + "-removal"
    }
    package static func linkTarget(_ name: String, sessionDirectory: URL) -> String {
        sessionDirectory.path + "/" + payloadDirectory + "/" + name
    }
    /// Absolute, standardized and free of NUL/dot components. The caller has
    /// already validated containment under the actual sessions directory.
    package static func isCanonicalDirectory(_ url: URL) -> Bool {
        let path = url.path
        return url.isFileURL && path.hasPrefix("/") && path.count > 1 && !path.hasSuffix("/")
            && !path.utf8.contains(0) && url.standardizedFileURL.path == path
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    /// Structural validation only; never touches disk. Restore and the launch
    /// layer call this before trusting any persisted ownership claim.
    public func validate(prefix expectedPrefix: URL, sessionID expectedSession: UUID) throws {
        func fail(_ reason: String) -> LauncherError { .journalCorrupt("Native proxy record: " + reason) }
        guard version == Self.currentVersion else { throw fail("unsupported version") }
        guard sessionID == expectedSession else { throw fail("belongs to another session") }
        guard Self.isCanonicalDirectory(prefix), Self.isCanonicalDirectory(sessionDirectory),
            prefix.path == expectedPrefix.standardizedFileURL.path else { throw fail("prefix or session path mismatch") }
        guard sessionDirectory.path != prefix.path, !sessionDirectory.path.hasPrefix(prefix.path + "/"),
            !prefix.path.hasPrefix(sessionDirectory.path + "/") else { throw fail("session and prefix overlap") }

        // Exactly the accepted two-DLL baseline: no subset, duplicate or reordering.
        guard originals.map(\.name) == Self.dllNames else { throw fail("unexpected originals") }
        for entry in originals {
            let print = entry.original
            guard entry.hiddenName == Self.hiddenName(entry.name, sessionID: sessionID),
                print.size >= 0, print.sha256.algorithm == .sha256, print.stamp.size == print.size,
                print.stamp.links == 1, print.stamp.kind == UInt32(S_IFREG),
                print.identity.device == print.stamp.device, print.identity.inode == print.stamp.inode else {
                throw fail("invalid original entry")
            }
        }
        guard files.map(\.name) == Self.fileNames else { throw fail("unexpected placed files") }
        for entry in files {
            guard entry.stageName == Self.stageName(entry.name, sessionID: sessionID),
                entry.sourcePath.components == [Self.payloadDirectory, entry.name],
                entry.size >= 0, entry.sha256.algorithm == .sha256,
                (entry.state == .planned) == (entry.identity == nil) || entry.state == .removed else {
                throw fail("invalid placed file entry")
            }
            if let identity = entry.identity, originals.contains(where: {
                $0.original.identity.device == identity.device && $0.original.identity.inode == identity.inode }) {
                throw fail("placed file claims an original inode")
            }
            // A DLL is staged only after its original is hidden, and an original
            // returns only to a name whose placed copy is already removed.
            if let original = originals.first(where: { $0.name == entry.name }) {
                if entry.state == .staged || entry.state == .placed, original.state != .hidden {
                    throw fail("placed file without a hidden original")
                }
                if original.state == .restored, entry.state != .removed { throw fail("original restored over a placed file") }
            }
        }
        guard links.map(\.name) == Self.linkNames else { throw fail("unexpected links") }
        for entry in links {
            guard entry.target == Self.linkTarget(entry.name, sessionDirectory: sessionDirectory),
                entry.state != .linked || entry.stamp?.kind == UInt32(S_IFLNK) else {
                throw fail("invalid link entry")
            }
        }
        // Nothing is mutated before the removal area is recorded.
        if removalArea == nil {
            guard originals.allSatisfy({ $0.state != .hidden }),
                files.allSatisfy({ $0.identity == nil && ($0.state == .planned || $0.state == .removed) }),
                links.allSatisfy({ $0.stamp == nil && $0.state != .linked }) else { throw fail("mutation without a removal area") }
        }
        if phase == .placed {
            guard originals.allSatisfy({ $0.state == .hidden }), files.allSatisfy({ $0.state == .placed }),
                links.allSatisfy({ $0.state == .linked }) else { throw fail("incomplete placed phase") }
        }
    }

    /// True once every owned entry has been verified as restored or removed.
    package var allResolved: Bool {
        originals.allSatisfy { $0.state == .restored } && files.allSatisfy { $0.state == .removed }
            && links.allSatisfy { $0.state == .removed }
    }
}
