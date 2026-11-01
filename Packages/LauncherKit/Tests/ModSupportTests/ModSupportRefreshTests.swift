// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport
import Testing

private func makeLibraryMod(in library: URL, name: String,
    extra: [String: Data] = [:]) throws -> URL {
    let folder = library.appendingPathComponent(name, isDirectory: true)
    try writeFile(Data("[TextureOverride]\nhash = fixture\n".utf8),
        to: folder.appendingPathComponent("mod.ini"))
    try writeFile(Data("DDS fixture".utf8), to: folder.appendingPathComponent("textures/body.dds"))
    for (path, data) in extra { try writeFile(data, to: folder.appendingPathComponent(path)) }
    return folder
}

@Test func refreshAdoptsManualFoldersWithStableIDsAndPreservesEnabledState() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let library = try await store.modsDirectoryURL()
    let firefly = try makeLibraryMod(in: library, name: "Firefly")
    _ = try makeLibraryMod(in: library, name: "Trailblazer")

    let first = try await store.refreshModLibrary()
    #expect(first.added == 2)
    #expect(first.removed == 0)
    #expect(first.rejected.isEmpty)

    var snapshot = try await store.snapshot()
    let adopted = try #require(snapshot.mods.first { $0.name == "Firefly" })
    #expect(snapshot.mods.count == 2)
    #expect(!adopted.enabled)
    #expect(adopted.fileCount == 2)
    #expect(adopted.id != "Firefly")

    try await store.setModEnabled(id: adopted.id, enabled: false)
    let unchanged = try await store.refreshModLibrary()
    #expect(!unchanged.changed)
    snapshot = try await store.snapshot()
    #expect(snapshot.mods.first { $0.id == adopted.id }?.enabled == false)

    let addedFile = "textures/extra.dds"
    try writeFile(Data("extra".utf8), to: firefly.appendingPathComponent(addedFile))
    let updated = try await store.refreshModLibrary()
    #expect(updated.updated == 1)
    snapshot = try await store.snapshot()
    #expect(snapshot.mods.first { $0.id == adopted.id }?.fileCount == 3)
    #expect(snapshot.mods.first { $0.id == adopted.id }?.enabled == false)

    try FileManager.default.removeItem(at: library.appendingPathComponent("Trailblazer", isDirectory: true))
    let removed = try await store.refreshModLibrary()
    #expect(removed.removed == 1)
    snapshot = try await store.snapshot()
    #expect(snapshot.mods.map(\.id) == [adopted.id])

    let renamed = library.appendingPathComponent("Firefly Renamed", isDirectory: true)
    try FileManager.default.moveItem(at: firefly, to: renamed)
    let renamedResult = try await store.refreshModLibrary()
    #expect(renamedResult.removed == 1)
    #expect(renamedResult.added == 1)
    snapshot = try await store.snapshot()
    #expect(snapshot.mods.map(\.name) == ["Firefly Renamed"])
    #expect(!snapshot.mods.contains { $0.id == adopted.id })
    #expect(snapshot.mods.first?.enabled == false)
}

@Test func refreshKeepsImportedModIdentityAndDisabledState() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let source = try makeModFolder(root: root, name: "Imported Mod")
    try await store.importMod(from: source)
    let imported = try #require(try await store.snapshot().mods.first)
    try await store.setModEnabled(id: imported.id, enabled: false)

    let result = try await store.refreshModLibrary()
    #expect(!result.changed)
    let snapshot = try await store.snapshot()
    #expect(snapshot.mods.count == 1)
    #expect(snapshot.mods.first?.id == imported.id)
    #expect(snapshot.mods.first?.name == imported.name)
    #expect(snapshot.mods.first?.enabled == false)
}

@Test func refreshRejectsUnsafeManualFoldersWithoutDeletingThem() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let library = try await store.modsDirectoryURL()
    let unsafe = try makeLibraryMod(in: library, name: "Unsafe Mod",
        extra: ["payload.exe": Data([0x4D, 0x5A, 0x00, 0x00])])
    _ = try makeLibraryMod(in: library, name: "No INI", extra: ["readme.txt": Data("notes".utf8)])
    try FileManager.default.removeItem(at: library.appendingPathComponent("No INI/mod.ini"))
    _ = try makeLibraryMod(in: library, name: "Safe Mod")

    let result = try await store.refreshModLibrary()
    #expect(result.added == 1)
    #expect(result.rejected.sorted() == ["No INI", "Unsafe Mod"])

    let snapshot = try await store.snapshot()
    #expect(snapshot.mods.map(\.name) == ["Safe Mod"])
    #expect(FileManager.default.fileExists(atPath: unsafe.appendingPathComponent("payload.exe").path))
    #expect(try Data(contentsOf: unsafe.appendingPathComponent("payload.exe")) == Data([0x4D, 0x5A, 0x00, 0x00]))
}

@Test func refreshSkipsHiddenLibraryEntriesAndFiles() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let library = try await store.modsDirectoryURL()
    _ = try makeLibraryMod(in: library, name: "Visible")
    try writeFile(Data("notes".utf8), to: library.appendingPathComponent("notes.txt"))
    try FileManager.default.createDirectory(at: library.appendingPathComponent(".macgacha-remove-fixture"),
        withIntermediateDirectories: true)

    let result = try await store.refreshModLibrary()
    #expect(result.added == 1)
    #expect(result.rejected.isEmpty)
    #expect(try await store.snapshot().mods.map(\.name) == ["Visible"])
}

@Test func refreshFailsClosedWhenTheSelectedLibraryIsUnavailable() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let library = try await store.modsDirectoryURL()
    _ = try makeLibraryMod(in: library, name: "Kept")
    _ = try await store.refreshModLibrary()
    let before = try await store.snapshot()

    let destination = root.appendingPathComponent("Unplugged/Mods", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try await store.moveModsDirectory(to: destination)
    try FileManager.default.removeItem(at: destination)

    await #expect(throws: LauncherError.self) { try await store.refreshModLibrary() }
    #expect(try await store.snapshot().mods == before.mods)
}

@Test func refreshPreservesDisabledRecordWhenFolderIsTemporarilyRejected() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let library = try await store.modsDirectoryURL()
    let folder = try makeLibraryMod(in: library, name: "Firefly")
    _ = try await store.refreshModLibrary()
    let mod = try #require(try await store.snapshot().mods.first)
    #expect(mod.folderPath == "Firefly")
    try await store.setModEnabled(id: mod.id, enabled: false)
    let badFile = folder.appendingPathComponent("bad.exe")
    try writeFile(Data([0x4d, 0x5a]), to: badFile)
    let rejected = try await store.refreshModLibrary()
    #expect(rejected.removed == 0)
    #expect(rejected.rejected == ["Firefly"])
    #expect(try await store.snapshot().mods.first?.enabled == false)
    try FileManager.default.removeItem(at: badFile)
    _ = try await store.refreshModLibrary()
    #expect(try await store.snapshot().mods.first?.id == mod.id)
    #expect(try await store.snapshot().mods.first?.enabled == false)
}

@Test func refreshRejectsWhitespaceFolderWithoutBlockingSafeSibling() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let library = try await store.modsDirectoryURL()
    _ = try makeLibraryMod(in: library, name: "Trailing ")
    _ = try makeLibraryMod(in: library, name: "Valid")
    let result = try await store.refreshModLibrary()
    #expect(result.rejected == ["Trailing "])
    #expect(result.added == 1)
    #expect(try await store.snapshot().mods.map(\.name) == ["Valid"])
}
