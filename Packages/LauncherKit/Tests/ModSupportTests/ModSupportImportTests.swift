// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport
import Testing

@Test func importsFolderAndZipWithoutTouchingSources() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let folder = try makeModFolder(root: root, name: "Super Mod")
    try await store.importMod(from: folder)
    var snapshot = try await store.snapshot()
    #expect(snapshot.mods.count == 1)
    #expect(snapshot.mods[0].name == "Super Mod")
    #expect(snapshot.mods[0].enabled)
    #expect(snapshot.mods[0].fileCount == 2)
    #expect(try Data(contentsOf: folder.appendingPathComponent("mod.ini"))
        == Data("[TextureOverride]\nhash = fixture\n".utf8))

    let zipSource = root.appendingPathComponent("zip-source/\(UUID().uuidString)", isDirectory: true)
    try writeFile(Data("[TextureOverride]\nzip = 1\n".utf8),
        to: zipSource.appendingPathComponent("Zip Mod/mod.ini"))
    try writeFile(Data("DDS zip".utf8), to: zipSource.appendingPathComponent("Zip Mod/texture.dds"))
    let archive = root.appendingPathComponent("zip-mod-\(UUID().uuidString).zip")
    try makeZip(source: zipSource, archive: archive)
    try await store.importMod(from: archive)

    snapshot = try await store.snapshot()
    #expect(snapshot.mods.count == 2)
    #expect(snapshot.mods.map(\.name).sorted() == ["Super Mod", "Zip Mod"])
    #expect(try Data(contentsOf: archive).count > 0)
}

@Test func duplicateImportsAreRejectedWithoutOverwriting() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let folder = try makeModFolder(root: root, name: "Cool Mod")
    try await store.importMod(from: folder)
    let before = try await store.snapshot()
    let originalID = try #require(before.mods.first?.id)

    do {
        try await store.importMod(from: folder)
        Issue.record("Duplicate folder import was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }

    let otherSource = root.appendingPathComponent("other-\(UUID().uuidString)", isDirectory: true)
    try writeFile(Data("[TextureOverride]\nother = 1\n".utf8),
        to: otherSource.appendingPathComponent("Cool Mod/mod.ini"))
    let archive = root.appendingPathComponent("duplicate-\(UUID().uuidString).zip")
    try makeZip(source: otherSource, archive: archive)
    do {
        try await store.importMod(from: archive)
        Issue.record("Duplicate ZIP import was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }

    let after = try await store.snapshot()
    #expect(after.mods.count == 1)
    #expect(after.mods[0].id == originalID)
    let library = try await store.modsDirectoryURL()
    #expect(try Data(contentsOf: library.appendingPathComponent(originalID).appendingPathComponent("mod.ini"))
        == Data("[TextureOverride]\nhash = fixture\n".utf8))
}

@Test func rejectsFolderSymlinksAndExecutables() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let symlinkMod = try makeModFolder(root: root, name: "Linked Mod")
    try FileManager.default.createSymbolicLink(at: symlinkMod.appendingPathComponent("escape.ini"),
        withDestinationURL: root.appendingPathComponent("outside.ini"))
    do {
        try await store.importMod(from: symlinkMod)
        Issue.record("Folder symlink was accepted")
    } catch let error as LauncherError {
        guard case .unsafePath = error else { throw error }
    }

    let exeMod = try makeModFolder(root: root, name: "Executable Mod",
        extra: ["payload/tool.exe": Data("MZ fixture".utf8)])
    do {
        try await store.importMod(from: exeMod)
        Issue.record("Executable was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    #expect(try await store.snapshot().mods.isEmpty)
}

@Test func rejectsZipTraversalAndZipSymlinks() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let outside = root.appendingPathComponent("outside.txt")
    try writeFile(Data("untouched".utf8), to: outside)

    let malicious = root.appendingPathComponent("malicious-\(UUID().uuidString)", isDirectory: true)
    try writeFile(Data("[TextureOverride]\nbad = 1\n".utf8),
        to: malicious.appendingPathComponent("mod.ini"))
    try writeFile(Data("evil".utf8), to: root.appendingPathComponent("evil.txt"))
    let traversal = root.appendingPathComponent("traversal-\(UUID().uuidString).zip")
    try makeZip(source: malicious, archive: traversal, extraArguments: ["../evil.txt"])
    do {
        try await store.importMod(from: traversal)
        Issue.record("ZIP traversal was accepted")
    } catch let error as LauncherError {
        guard case .unsafePath = error else { throw error }
    }
    #expect(try Data(contentsOf: outside) == Data("untouched".utf8))

    let linkedSource = root.appendingPathComponent("linked-\(UUID().uuidString)", isDirectory: true)
    try writeFile(Data("[TextureOverride]\nlink = 1\n".utf8),
        to: linkedSource.appendingPathComponent("Linked Mod/mod.ini"))
    try FileManager.default.createSymbolicLink(
        atPath: linkedSource.appendingPathComponent("Linked Mod/alias.ini").path,
        withDestinationPath: "mod.ini")
    let linkedZip = root.appendingPathComponent("linked-\(UUID().uuidString).zip")
    try makeZip(source: linkedSource, archive: linkedZip, storeSymlinks: true)
    do {
        try await store.importMod(from: linkedZip)
        Issue.record("ZIP symlink was accepted")
    } catch let error as LauncherError {
        guard case .unsafePath = error else { throw error }
    }
    #expect(try await store.snapshot().mods.isEmpty)
}
