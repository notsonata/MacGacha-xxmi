// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
@testable import ModSupport
import Synchronization
import Testing

private func makeLibraryDestination(root: URL, name: String = "MacGacha-HSR-Mods") throws -> URL {
    let parent = root.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return parent.appendingPathComponent(name, isDirectory: true)
}

private func defaultLibrary(_ paths: AppPaths) -> URL {
    paths.root.appendingPathComponent("XXMI/Games/starrail/Mods", isDirectory: true)
}

@Test func relocationPersistsSelectionAndKeepsModsSettingsAndLaunchWorking() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let store = ModSupportStore(paths: paths)
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "Enabled Mod"))
    try await store.importMod(from: try makeModFolder(root: root, name: "Disabled Mod"))
    let before = try await store.snapshot()
    let enabledID = try #require(before.mods.first { $0.name == "Enabled Mod" }?.id)
    let disabledID = try #require(before.mods.first { $0.name == "Disabled Mod" }?.id)
    try await store.setModEnabled(id: disabledID, enabled: false)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)

    let destination = try makeLibraryDestination(root: root)
    #expect(!destination.path.hasPrefix(paths.root.path + "/"))
    try await store.moveModsDirectory(to: destination)

    let moved = try await store.snapshot()
    #expect(moved.modsDirectory?.path == destination.path)
    #expect(try await store.modsDirectoryURL().path == destination.path)
    #expect(moved.mods.first { $0.id == enabledID }?.enabled == true)
    #expect(moved.mods.first { $0.id == disabledID }?.enabled == false)
    #expect(!FileManager.default.fileExists(atPath: defaultLibrary(paths).path))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(enabledID).path))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(disabledID).path))

    let backend = try makeBackend(root: root)
    let prepared = try #require(try await store.prepareLaunch(gameID: "starrail",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    #expect(prepared.sessionDirectory.path.hasPrefix(paths.root.path + "/"))
    let sessionMods = prepared.sessionDirectory.appendingPathComponent("payload/Mods")
    #expect(try FileManager.default.contentsOfDirectory(atPath: sessionMods.path).sorted() == [enabledID])

    let newFolder = try makeModFolder(root: root, name: "After Move")
    try await store.importMod(from: newFolder)
    let imported = try await store.snapshot()
    let importedID = try #require(imported.mods.first { $0.name == "After Move" }?.id)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(importedID).path))
    try await store.removeMod(id: importedID)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(importedID).path))

    let restarted = ModSupportStore(paths: paths)
    let restored = try await restarted.snapshot()
    #expect(restored.modsDirectory?.path == destination.path)
    #expect(restored.mods.first { $0.id == enabledID }?.enabled == true)
    #expect(restored.mods.first { $0.id == disabledID }?.enabled == false)
    #expect(restored.installedVersion == fixtureVersion)
    #expect(try await restarted.modsDirectoryURL().path == destination.path)
}

@Test func relocationKeepsAlreadyPreparedSnapshotsIntact() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "Snapshot Mod"))
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    let backend = try makeBackend(root: root)
    let first = try #require(try await store.prepareLaunch(gameID: "starrail",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    let sessionINI = first.sessionDirectory.appendingPathComponent("payload/Mods")
    let before = try FileManager.default.contentsOfDirectory(atPath: sessionINI.path).sorted()

    let destination = try makeLibraryDestination(root: root)
    try await store.moveModsDirectory(to: destination)

    #expect(FileManager.default.fileExists(atPath: first.runnerURL.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: sessionINI.path).sorted() == before)
    let second = try #require(try await store.prepareLaunch(gameID: "starrail",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    #expect(second.sessionDirectory != first.sessionDirectory)
    #expect(FileManager.default.fileExists(atPath: second.runnerURL.path))
}

@Test func relocationBackToDefaultClearsTheCustomLocation() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let store = ModSupportStore(paths: paths)
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "Round Trip"))
    let destination = try makeLibraryDestination(root: root)
    try await store.moveModsDirectory(to: destination)
    try await store.moveModsDirectory(to: defaultLibrary(paths))

    let snapshot = try await store.snapshot()
    #expect(snapshot.modsDirectory?.path == defaultLibrary(paths).path)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: defaultLibrary(paths).path).count == 1)
}

@Test func relocationRejectsNonemptySymlinkedManagedAndNestedDestinations() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let store = ModSupportStore(paths: paths)
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "Kept Mod"))
    let before = try await store.snapshot()
    let modID = try #require(before.mods.first?.id)

    let occupied = try makeLibraryDestination(root: root)
    try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
    try writeFile(Data("foreign".utf8), to: occupied.appendingPathComponent("keep.txt"))
    await expectLibraryError { try await store.moveModsDirectory(to: occupied) }
    #expect(try Data(contentsOf: occupied.appendingPathComponent("keep.txt")) == Data("foreign".utf8))

    let realEmpty = try makeLibraryDestination(root: root)
    try FileManager.default.createDirectory(at: realEmpty, withIntermediateDirectories: true)
    let symlinked = try makeLibraryDestination(root: root)
    try FileManager.default.createSymbolicLink(at: symlinked, withDestinationURL: realEmpty)
    await expectLibraryError { try await store.moveModsDirectory(to: symlinked) }

    let managed = paths.root.appendingPathComponent("XXMI/Games/starrail/Packages/Mods",
        isDirectory: true)
    await expectLibraryError { try await store.moveModsDirectory(to: managed) }

    try await store.moveModsDirectory(to: try makeLibraryDestination(root: root))
    let nested = (try await store.modsDirectoryURL()).appendingPathComponent("Nested", isDirectory: true)
    await expectLibraryError { try await store.moveModsDirectory(to: nested) }
    let outer = (try await store.modsDirectoryURL()).deletingLastPathComponent()
    await expectLibraryError { try await store.moveModsDirectory(to: outer) }

    let after = try await store.snapshot()
    let current = try await store.modsDirectoryURL()
    #expect(after.modsDirectory?.path == current.path)
    #expect(after.mods.first?.id == modID)
    #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent(modID).path))
}

@Test func failedDestinationSyncLeavesTheOriginalLibraryUsable() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let ops = FailDestinationSyncOps()
    let store = ModSupportStore(paths: paths, fileOps: ops)
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "Safe Mod"))
    let modID = try #require(try await store.snapshot().mods.first?.id)
    let destination = try makeLibraryDestination(root: root)
    ops.arm(destination.path)

    await expectLibraryError { try await store.moveModsDirectory(to: destination) }
    let snapshot = try await store.snapshot()
    #expect(snapshot.modsDirectory?.path == defaultLibrary(paths).path)
    #expect(FileManager.default.fileExists(atPath: defaultLibrary(paths).appendingPathComponent(modID).path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func failedLocationCommitRollsBackTheCopy() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let ops = FailLocationStateSyncOps()
    let store = ModSupportStore(paths: paths, fileOps: ops)
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "Rollback Mod"))
    let modID = try #require(try await store.snapshot().mods.first?.id)
    let destination = try makeLibraryDestination(root: root)
    ops.arm()

    await expectLibraryError { try await store.moveModsDirectory(to: destination) }
    let snapshot = try await store.snapshot()
    #expect(snapshot.modsDirectory?.path == defaultLibrary(paths).path)
    #expect(FileManager.default.fileExists(atPath: defaultLibrary(paths).appendingPathComponent(modID).path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func unavailableCustomLibraryFailsClosedAndKeepsTheSelectedPath() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let store = ModSupportStore(paths: paths)
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "External Mod"))
    let modID = try #require(try await store.snapshot().mods.first?.id)
    let destination = try makeLibraryDestination(root: root)
    try await store.moveModsDirectory(to: destination)
    try FileManager.default.removeItem(at: destination)

    let snapshot = try await store.snapshot()
    #expect(snapshot.modsDirectory?.path == destination.path)
    #expect(snapshot.mods.first?.id == modID)
    #expect(try await store.modsDirectoryURL().path == destination.path)

    do {
        try await store.importMod(from: try makeModFolder(root: root, name: "Blocked"))
        Issue.record("Import into a missing custom library was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    do {
        try await store.removeMod(id: modID)
        Issue.record("Removal from a missing custom library was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try await store.snapshot().mods.first?.id == modID)

    let backend = try makeBackend(root: root)
    #expect(try await store.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime,
        backendD3D11: backend) == nil)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    do {
        _ = try await store.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime,
            backendD3D11: backend)
        Issue.record("Enabled launch with a missing custom library was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
}

private func expectLibraryError(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Library operation was accepted")
    } catch let error as LauncherError {
        switch error {
        case .io, .unsafePath, .journalCorrupt: break
        default: Issue.record("Unexpected LauncherError: \(error)")
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private final class FailDestinationSyncOps: FileOps, @unchecked Sendable {
    private let armedPath = Mutex<String?>(nil)

    func arm(_ path: String) {
        armedPath.withLock { $0 = URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    }

    func disarm() { armedPath.withLock { $0 = nil } }

    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try SystemFileOps().write(descriptor, bytes: bytes)
    }

    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        let target = armedPath.withLock { $0 }
        if let target, let path = Self.path(of: descriptor) {
            let actual = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if actual == target || actual.hasPrefix(target + "/") {
                throw LauncherError.io("Injected destination sync failure")
            }
        }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }

    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination,
            in: destinationDirectory, exclusive: exclusive)
    }

    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }

    private static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) >= 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }
}

private final class FailLocationStateSyncOps: FileOps, @unchecked Sendable {
    private let armed = Mutex(false)

    func arm() { armed.withLock { $0 = true } }

    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try SystemFileOps().write(descriptor, bytes: bytes)
    }

    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        let fail = armed.withLock { value in
            guard value, let path = Self.path(of: descriptor) else { return false }
            let parent = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            guard parent.hasSuffix("/XXMI/Games/starrail"),
                name.hasPrefix(".macgacha-write-") else { return false }
            value = false
            return true
        }
        if fail { throw LauncherError.io("Injected location state sync failure") }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }

    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination,
            in: destinationDirectory, exclusive: exclusive)
    }

    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }

    private static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) >= 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }
}

@Test func relocationRejectsASymlinkedSourceLibrary() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "Linked Source"))
    let first = try makeLibraryDestination(root: root)
    try await store.moveModsDirectory(to: first)
    let movedAway = root.appendingPathComponent("moved-away-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.moveItem(at: first, to: movedAway)
    try FileManager.default.createSymbolicLink(at: first, withDestinationURL: movedAway)

    await expectLibraryError { try await store.moveModsDirectory(
        to: try makeLibraryDestination(root: root)) }
    let snapshot = try await store.snapshot()
    #expect(snapshot.modsDirectory?.path == first.path)
    #expect(snapshot.mods.count == 1)
    #expect(FileManager.default.fileExists(atPath: movedAway.appendingPathComponent(
        try #require(snapshot.mods.first).id).path))
}

@Test func relocationAdoptsAnExistingEmptyDestination() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.importMod(from: try makeModFolder(root: root, name: "Adopted Library"))
    let destination = try makeLibraryDestination(root: root)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    try await store.moveModsDirectory(to: destination)
    let snapshot = try await store.snapshot()
    let id = try #require(snapshot.mods.first?.id)
    #expect(snapshot.modsDirectory?.path == destination.path)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(id).path))
}

@Test func legacyStateWithoutACustomLibraryUsesTheManagedLocation() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let state = Data(("{\"schemaVersion\":1,\"injectionEnabled\":false,\"riskAcknowledged\":false,"
        + "\"mods\":[]}").utf8)
    try writeFile(state, to: paths.root.appendingPathComponent(
        "XXMI/Games/starrail/state.json"))

    let store = ModSupportStore(paths: paths)
    let snapshot = try await store.snapshot()
    #expect(snapshot.modsDirectory?.path == defaultLibrary(paths).path)
    #expect(snapshot.mods.isEmpty)
    #expect(!snapshot.injectionEnabled)
}

@Test func failedImportIntoRelocatedLibraryDoesNotLeaveAnOrphanDirectory() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let ops = FailDestinationSyncOps()
    let store = ModSupportStore(paths: appPaths(root), fileOps: ops)
    let destination = try makeLibraryDestination(root: root)
    try await store.moveModsDirectory(to: destination)
    let source = try makeModFolder(root: root, name: "Retry Import")
    ops.arm(destination.path)
    await expectLibraryError { try await store.importMod(from: source) }
    ops.disarm()
    #expect(try await store.snapshot().mods.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    try await store.importMod(from: source)
    #expect(try await store.snapshot().mods.count == 1)
}

@Test func selectedLibraryHandleDoesNotRecreateAReplacedPath() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let selected = try makeLibraryDestination(root: root)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    var state = ModSupportState()
    state.modsDirectory = selected.path
    let library = try ModSupportStore.libraryFileSystem(state: state,
        layout: ModSupportLayout(paths: paths), fileOps: SystemFileOps())
    let renamed = selected.deletingLastPathComponent().appendingPathComponent("OriginalLibrary")
    try FileManager.default.moveItem(at: selected, to: renamed)
    try library.createDirectory(at: SafeRelativePath("new-mod"))
    #expect(!FileManager.default.fileExists(atPath: selected.path))
    #expect(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("new-mod").path))
}
