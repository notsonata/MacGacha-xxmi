// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
@testable import ModSupport
import Testing

// Synthetic fixtures only: every file lives in a per-test temporary root.

/// Bytes of an APFS file that are not shared with another file. A clone has none until it diverges.
private func privateBytes(_ url: URL) throws -> Int64 {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    var buffer = [UInt8](repeating: 0, count: 64)
    guard getattrlist(url.path, &list, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else {
        throw LauncherError.io("Cannot read private size")
    }
    return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
}

/// True when the temporary volume supports `clonefile`, so clone assertions are meaningful.
private func volumeClones(in root: URL) throws -> Bool {
    let probe = root.appendingPathComponent("clone-probe-\(UUID().uuidString)")
    try writeFile(Data(repeating: 7, count: 8_192), to: probe)
    let copy = root.appendingPathComponent("clone-probe-copy-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: probe); try? FileManager.default.removeItem(at: copy) }
    return clonefile(probe.path, copy.path, 0) == 0
}

private func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

private struct CloneFixture {
    let root: URL
    let folder: URL
    let sourceFS: ContainedFileSystem
    let sourcePath: SafeRelativePath
    let large: Data

    init(root: URL, extra: [String: Data] = [:]) throws {
        self.root = root
        large = randomData(1_048_576)
        var files = extra
        files["textures/large.dds"] = large
        folder = try makeModFolder(root: root, name: "Clone Mod", extra: files)
        sourceFS = try ContainedFileSystem(root: folder.deletingLastPathComponent())
        sourcePath = try SafeRelativePath(folder.lastPathComponent)
    }

    func destination(_ name: String) throws -> (URL, ContainedFileSystem) {
        let url = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, try ContainedFileSystem(root: url))
    }

    @discardableResult
    func copy(to destination: ContainedFileSystem, as name: String, validate: Bool = true,
        hook: ((ContainedFileSystem, SafeRelativePath) throws -> Void)? = nil) throws -> ModTreeScan {
        try ModSupportFileSystem.copyContents(from: sourceFS, sourceDirectory: sourcePath,
            to: destination, destinationDirectory: SafeRelativePath(name), validateModContent: validate,
            limit: .mod, afterSourceValidation: hook)
    }
}

private func overwriteInPlace(_ url: URL, with data: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
}

@Test func copyContentsStreamsLargeRegularFilesEvenOnCloneCapableVolumes() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let (library, libraryFS) = try fixture.destination("library")
    let scan = try fixture.copy(to: libraryFS, as: "clone-mod")

    let copied = library.appendingPathComponent("clone-mod/textures/large.dds")
    #expect(try Data(contentsOf: copied) == fixture.large)
    #expect(scan.files["textures/large.dds"] == Int64(fixture.large.count))
    #expect(scan.iniCount == 1)
    guard try volumeClones(in: root) else { return }
    // Optional cloning is deferred; every destination is exclusively created.
    #expect(try privateBytes(copied) == Int64(fixture.large.count))
}

@Test func libraryAndSessionCopiesDivergeWithoutTouchingEachOther() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let (library, libraryFS) = try fixture.destination("library")
    try fixture.copy(to: libraryFS, as: "mod")

    // The launch session copies from the library, exactly like copyEnabledMods.
    let (session, sessionFS) = try fixture.destination("session")
    _ = try ModSupportFileSystem.copyContents(from: libraryFS, sourceDirectory: SafeRelativePath("mod"),
        to: sessionFS, destinationDirectory: SafeRelativePath("Mods/mod"), validateModContent: true, limit: .mod)

    let source = fixture.folder.appendingPathComponent("textures/large.dds")
    let libraryFile = library.appendingPathComponent("mod/textures/large.dds")
    let sessionFile = session.appendingPathComponent("Mods/mod/textures/large.dds")

    // The game (through Wine) rewrites the session file in place.
    let sessionEdit = randomData(4_096)
    try overwriteInPlace(sessionFile, with: sessionEdit)
    #expect(try Data(contentsOf: sessionFile) == sessionEdit)
    #expect(try Data(contentsOf: libraryFile) == fixture.large)
    #expect(try Data(contentsOf: source) == fixture.large)

    // An edit to the library copy must not reach the already-built session or the original folder.
    let libraryEdit = randomData(8_192)
    try overwriteInPlace(libraryFile, with: libraryEdit)
    #expect(try Data(contentsOf: sessionFile) == sessionEdit)
    #expect(try Data(contentsOf: source) == fixture.large)

    // And rewriting the user's original folder after import does not change the library.
    let sourceEdit = randomData(2_048)
    try overwriteInPlace(source, with: sourceEdit)
    #expect(try Data(contentsOf: libraryFile) == libraryEdit)
    #expect(try Data(contentsOf: sessionFile) == sessionEdit)
}

@Test func copiedFilesAreNeverExecutableOrCarryExtendedAttributes() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let marked = fixture.folder.appendingPathComponent("mod.ini")
    #expect(chmod(marked.path, 0o4755) == 0)
    let quarantine = Array("0081;00000000;Fixture;".utf8)
    #expect(setxattr(marked.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)
    let readOnly = fixture.folder.appendingPathComponent("textures/body.dds")
    #expect(chmod(readOnly.path, 0o444) == 0)

    let (library, libraryFS) = try fixture.destination("library")
    try fixture.copy(to: libraryFS, as: "mod")

    for relative in ["mod/mod.ini", "mod/textures/body.dds", "mod/textures/large.dds"] {
        let url = library.appendingPathComponent(relative)
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o600, "\(relative) mode \(String(info.st_mode & 0o7777, radix: 8))")
        #expect(listxattr(url.path, nil, 0, XATTR_NOFOLLOW) <= 0, "\(relative) kept extended attributes")
    }
    // The original keeps its own mode and quarantine marker.
    var original = stat()
    #expect(lstat(marked.path, &original) == 0 && original.st_mode & 0o7777 == 0o4755)
    #expect(getxattr(marked.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
}

@Test func copyContentsRejectsASourceThatGrowsAfterItsSizeWasRecorded() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let (_, libraryFS) = try fixture.destination("library")
    var mutated = false
    do {
        try fixture.copy(to: libraryFS, as: "mod") { _, path in
            guard !mutated, path.components.last == "large.dds" else { return }
            mutated = true
            try overwriteInPlace(fixture.folder.appendingPathComponent("textures/large.dds"),
                with: fixture.large + Data("grown".utf8))
        }
        Issue.record("A source that grew after validation was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    #expect(mutated)
}

@Test func copyContentsRejectsASourceThatShrinksAfterItsSizeWasRecorded() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let (_, libraryFS) = try fixture.destination("library")
    var mutated = false
    do {
        try fixture.copy(to: libraryFS, as: "mod") { _, path in
            guard !mutated, path.components.last == "large.dds" else { return }
            mutated = true
            try overwriteInPlace(fixture.folder.appendingPathComponent("textures/large.dds"),
                with: Data(fixture.large.prefix(1_024)))
        }
        Issue.record("A source that shrank after validation was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    #expect(mutated)
}

@Test func copyContentsRejectsExecutableMagicIntroducedAfterValidation() throws {
    let magics: [[UInt8]] = [
        [0x7F, 0x45, 0x4C, 0x46], // ELF
        [0xCF, 0xFA, 0xED, 0xFE], // 64-bit Mach-O
        [0xCA, 0xFE, 0xBA, 0xBE], // fat Mach-O
    ]
    for magic in magics {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let fixture = try CloneFixture(root: root)
        let (_, libraryFS) = try fixture.destination("library")
        var mutated = false
        do {
            try fixture.copy(to: libraryFS, as: "mod") { _, path in
                guard !mutated, path.components.last == "body.dds" else { return }
                mutated = true
                try overwriteInPlace(fixture.folder.appendingPathComponent("textures/body.dds"),
                    with: Data(magic + Array("payload".utf8)))
            }
            Issue.record("Executable magic \(magic) was accepted after validation")
        } catch let error as LauncherError {
            guard case .io = error else { throw error }
        }
        #expect(mutated)
    }
}

@Test func copyContentsRejectsExecutableExtensionsBeforeCopying() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root, extra: ["tools/helper.dll": Data("not code".utf8)])
    let (library, libraryFS) = try fixture.destination("library")
    do {
        try fixture.copy(to: libraryFS, as: "mod")
        Issue.record("A mod containing a .dll was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("mod/tools/helper.dll").path))
}

@Test func copyContentsNeverFollowsASymbolicLinkSwappedInAfterValidation() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let secret = Data("outside secret".utf8)
    let outside = root.appendingPathComponent("outside-secret.txt")
    try writeFile(secret, to: outside)
    let (library, libraryFS) = try fixture.destination("library")
    var swapped = false
    do {
        try fixture.copy(to: libraryFS, as: "mod") { _, path in
            guard !swapped, path.components.last == "large.dds" else { return }
            swapped = true
            let target = fixture.folder.appendingPathComponent("textures/large.dds")
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        }
        Issue.record("A swapped-in symbolic link was copied")
    } catch is LauncherError {
        // Any contained-file-system refusal is acceptable; what matters is that nothing leaked.
    }
    #expect(swapped)
    let copied = library.appendingPathComponent("mod/textures/large.dds")
    if let data = try? Data(contentsOf: copied) { #expect(data != secret) }
}

@Test func copyContentsRefusesSymbolicLinkLeavesInTheSource() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let outside = root.appendingPathComponent("outside-secret.txt")
    try writeFile(Data("outside secret".utf8), to: outside)
    try FileManager.default.createSymbolicLink(
        at: fixture.folder.appendingPathComponent("link.txt"), withDestinationURL: outside)
    let (library, libraryFS) = try fixture.destination("library")
    do {
        try fixture.copy(to: libraryFS, as: "mod")
        Issue.record("A symbolic link inside a mod was accepted")
    } catch let error as LauncherError {
        guard case .unsafePath = error else { throw error }
    }
    #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("mod/link.txt").path))
}

@Test func copyContentsRejectsAFileSubstitutedBeforeDestinationCreation() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let (library, libraryFS) = try fixture.destination("library")
    let stale = library.appendingPathComponent("mod/textures/large.dds")
    try writeFile(Data("stale and much longer than nothing".utf8), to: stale)
    #expect(throws: LauncherError.self) { try fixture.copy(to: libraryFS, as: "mod") }
    #expect(try Data(contentsOf: stale) == Data("stale and much longer than nothing".utf8))
}

// A legacy clone preference must not bypass exclusive streaming or its ownership checks.
@Test(arguments: [true, false])
func copyFileHonorsTheRecordedSizeAndNormalizesPermissionsRegardlessOfClonePreference(preferClone: Bool) throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let (library, libraryFS) = try fixture.destination("library")
    let source = try SafeRelativePath(fixture.sourcePath.description + "/textures/large.dds")
    let size = Int64(fixture.large.count)
    #expect(chmod(fixture.folder.appendingPathComponent("textures/large.dds").path, 0o755) == 0)

    try ModSupportFileSystem.copyFile(fixture.sourceFS, source, libraryFS, SafeRelativePath("ok/large.dds"),
        size: size, preferClone: preferClone)
    let copied = library.appendingPathComponent("ok/large.dds")
    #expect(try Data(contentsOf: copied) == fixture.large)
    var info = stat()
    #expect(lstat(copied.path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
    if !preferClone, try volumeClones(in: root) { #expect(try privateBytes(copied) == size) }

    for wrong in [size - 1, size + 1] {
        let name = try SafeRelativePath("bad-\(wrong)/large.dds")
        do {
            try ModSupportFileSystem.copyFile(fixture.sourceFS, source, libraryFS, name, size: wrong,
                preferClone: preferClone)
            Issue.record("A recorded size of \(wrong) was accepted for \(size) bytes")
        } catch let error as LauncherError {
            guard case .io = error else { throw error }
        }
    }
}

// MARK: - Review regressions: retained-descriptor normalization, inode flags, ACL-only readability

private func fileMode(_ url: URL) throws -> mode_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw LauncherError.io("Cannot stat fixture") }
    return info.st_mode & 0o7777
}

private func fileFlags(_ url: URL) throws -> UInt32 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw LauncherError.io("Cannot stat fixture") }
    return info.st_flags
}

private struct OutsideFile {
    let url: URL
    let data = Data("outside file that must never be modified".utf8)
    static let attribute = "com.macgacha.test.marker"
    static let value = Array("keep".utf8)

    init(root: URL) throws {
        url = root.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try writeFile(data, to: url)
        #expect(chmod(url.path, 0o644) == 0)
        #expect(setxattr(url.path, Self.attribute, Self.value, Self.value.count, 0, 0) == 0)
    }

    func expectUntouched() throws {
        #expect(try fileMode(url) == 0o644)
        #expect(try Data(contentsOf: url) == data)
        var buffer = [UInt8](repeating: 0, count: 16)
        let length = getxattr(url.path, Self.attribute, &buffer, buffer.count, 0, 0)
        #expect(length == Self.value.count && Array(buffer.prefix(max(length, 0))) == Self.value)
    }
}

private func copySingleFile(_ fixture: CloneFixture, library: ContainedFileSystem, to name: String, size: Int64? = nil,
    preferClone: Bool, afterCopy: (() throws -> Void)? = nil) throws {
    let source = try SafeRelativePath(fixture.sourcePath.description + "/textures/large.dds")
    try ModSupportFileSystem.copyFile(fixture.sourceFS, source, library, SafeRelativePath(name),
        size: size ?? Int64(fixture.large.count), preferClone: preferClone, afterCopy: afterCopy)
}

// A destination swapped for a hard link to an unrelated inode between the copy and its
// normalization must never be chmod'ed or stripped of attributes through the new name.
@Test(arguments: [true, false])
func normalizationNeverModifiesAnInodeSubstitutedAfterTheCopy(preferClone: Bool) throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let outside = try OutsideFile(root: root)
    let (library, libraryFS) = try fixture.destination("library")
    let copied = library.appendingPathComponent("swap/large.dds")
    var swapped = false
    var failed = false
    do {
        try copySingleFile(fixture, library: libraryFS, to: "swap/large.dds", preferClone: preferClone) {
            swapped = true
            try FileManager.default.removeItem(at: copied)
            guard link(outside.url.path, copied.path) == 0 else { throw LauncherError.io("Cannot link fixture") }
        }
    } catch is LauncherError { failed = true }
    #expect(swapped)
    try outside.expectUntouched()
    // Refusal is unconditional, including on filesystems without clone support.
    #expect(failed)
    #expect(FileManager.default.fileExists(atPath: copied.path))
}

// UF_IMMUTABLE / UF_APPEND are inode flags a clone would inherit and then refuse chmod/unlink on.
@Test(arguments: [UInt32(UF_IMMUTABLE), UInt32(UF_APPEND)], [true, false])
func flaggedSourcesCopyToAnOrdinaryWritableFileRegardlessOfClonePreference(flag: UInt32, preferClone: Bool) throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let sourceURL = fixture.folder.appendingPathComponent("textures/large.dds")
    #expect(chflags(sourceURL.path, flag) == 0)
    defer { _ = chflags(sourceURL.path, 0) }
    let (library, libraryFS) = try fixture.destination("library")

    try copySingleFile(fixture, library: libraryFS, to: "flagged/large.dds", preferClone: preferClone)
    let copied = library.appendingPathComponent("flagged/large.dds")
    #expect(try Data(contentsOf: copied) == fixture.large)
    #expect(try fileMode(copied) == 0o600)
    #expect(try fileFlags(copied) & (UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)) == 0)
    // The original keeps its own flag.
    #expect(try fileFlags(sourceURL) & flag == flag)
    // The copy is an ordinary file: it can be rewritten and removed again.
    try overwriteInPlace(copied, with: Data("rewritten".utf8))
    try FileManager.default.removeItem(at: copied)
}

@Test func flaggedFilesInsideAWholeModTreeCopyAndTheTreeStaysRemovable() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let immutable = fixture.folder.appendingPathComponent("textures/large.dds")
    let append = fixture.folder.appendingPathComponent("textures/body.dds")
    #expect(chflags(immutable.path, UInt32(UF_IMMUTABLE)) == 0)
    #expect(chflags(append.path, UInt32(UF_APPEND)) == 0)
    defer { _ = chflags(immutable.path, 0); _ = chflags(append.path, 0) }
    let (library, libraryFS) = try fixture.destination("library")
    try fixture.copy(to: libraryFS, as: "mod")
    #expect(try Data(contentsOf: library.appendingPathComponent("mod/textures/large.dds")) == fixture.large)
    try FileManager.default.removeItem(at: library.appendingPathComponent("mod"))
}

@Test(arguments: [true, false])
func aFailedCopyLeavesNoDestinationBehind(preferClone: Bool) throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let (library, libraryFS) = try fixture.destination("library")
    struct Injected: Error {}
    do {
        try copySingleFile(fixture, library: libraryFS, to: "failed/large.dds", preferClone: preferClone) { throw Injected() }
        Issue.record("An injected failure was swallowed")
    } catch is Injected {}
    #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("failed/large.dds").path))
}

// A source that only the owner's ACL makes readable (mode 000) used to copy through the 0600 stream.
private func grantOwnerReadByACL(_ url: URL) throws -> Bool {
    guard chmod(url.path, 0) == 0 else { return false }
    let status = try runProcess("/bin/chmod",
        ["+a", "\(NSUserName()) allow read,readattr,readextattr,readsecurity", url.path], from: url.deletingLastPathComponent())
    guard status == 0, let handle = try? FileHandle(forReadingFrom: url) else { return false }
    try? handle.close()
    return true
}

@Test(arguments: [true, false])
func aSourceReadableOnlyThroughAnACLStillCopiesAsAnOwnerReadWriteFile(preferClone: Bool) throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let sourceURL = fixture.folder.appendingPathComponent("textures/large.dds")
    guard try grantOwnerReadByACL(sourceURL) else {
        Issue.record("Cannot make an ACL-readable mode 000 fixture on this volume")
        return
    }
    let (library, libraryFS) = try fixture.destination("library")
    try copySingleFile(fixture, library: libraryFS, to: "acl/large.dds", preferClone: preferClone)
    let copied = library.appendingPathComponent("acl/large.dds")
    #expect(try Data(contentsOf: copied) == fixture.large)
    #expect(try fileMode(copied) == 0o600)
    #expect(try fileMode(sourceURL) == 0)
}

@Test func anACLReadableModeZeroFileInsideAWholeModTreeImports() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    guard try grantOwnerReadByACL(fixture.folder.appendingPathComponent("textures/large.dds")) else {
        Issue.record("Cannot make an ACL-readable mode 000 fixture on this volume")
        return
    }
    let (library, libraryFS) = try fixture.destination("library")
    let scan = try fixture.copy(to: libraryFS, as: "mod")
    #expect(scan.files["textures/large.dds"] == Int64(fixture.large.count))
    #expect(try Data(contentsOf: library.appendingPathComponent("mod/textures/large.dds")) == fixture.large)
}

@Test(arguments: [true, false])
func aFileDirectlyUnderTheDestinationRootCopiesAndNormalizes(preferClone: Bool) throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let (library, libraryFS) = try fixture.destination("library")
    #expect(chmod(fixture.folder.appendingPathComponent("textures/large.dds").path, 0o755) == 0)
    try copySingleFile(fixture, library: libraryFS, to: "large.dds", preferClone: preferClone)
    let copied = library.appendingPathComponent("large.dds")
    #expect(try Data(contentsOf: copied) == fixture.large)
    #expect(try fileMode(copied) == 0o600)
}


@Test(arguments: [false, true])
func exclusiveCopyRejectsRenamedOrFlaggedForeignInodes(flaggedHardlink: Bool) throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let fixture = try CloneFixture(root: root)
    let outside = try OutsideFile(root: root)
    let (library, libraryFS) = try fixture.destination("library")
    let copied = library.appendingPathComponent("swap/large.dds")
    // Equal size prevents a size check from masking the identity substitution.
    try overwriteInPlace(outside.url, with: fixture.large)
    defer { _ = chflags(outside.url.path, 0); _ = chflags(copied.path, 0) }
    var failed = false
    do {
        try copySingleFile(fixture, library: libraryFS, to: "swap/large.dds", preferClone: true) {
            try FileManager.default.removeItem(at: copied)
            if flaggedHardlink {
                guard link(outside.url.path, copied.path) == 0 else { throw LauncherError.io("Cannot link fixture") }
                #expect(chflags(outside.url.path, UInt32(UF_IMMUTABLE | UF_APPEND)) == 0)
            } else {
                try FileManager.default.moveItem(at: outside.url, to: copied)
            }
        }
    } catch is LauncherError { failed = true }
    #expect(failed)
    #expect(try fileMode(copied) == 0o644)
    #expect(try Data(contentsOf: copied) == fixture.large)
    #expect(try fileFlags(copied) == (flaggedHardlink ? UInt32(UF_IMMUTABLE | UF_APPEND) : 0))
    var buffer = [UInt8](repeating: 0, count: 16)
    let length = getxattr(copied.path, OutsideFile.attribute, &buffer, buffer.count, 0, 0)
    #expect(length == OutsideFile.value.count)
}
