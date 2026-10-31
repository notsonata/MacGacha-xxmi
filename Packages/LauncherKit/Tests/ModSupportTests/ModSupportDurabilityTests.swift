// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import Synchronization
@testable import ModSupport
import Testing

@Test func installExtractsTheStagedArchiveAfterTheExternalSourceDisappears() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let package = try PackageFixture(root: root)
    let runner = MutatingArchiveSourceRunner(source: package.archive)
    let store = ModSupportStore(paths: appPaths(root), runner: runner)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    #expect(!FileManager.default.fileExists(atPath: package.archive.path))
    #expect(try await store.snapshot().installedVersion == fixtureVersion)
}

@Test func zipImportExtractsTheStagedArchiveAfterTheExternalSourceDisappears() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let source = root.appendingPathComponent("zip-source-\(UUID().uuidString)", isDirectory: true)
    try writeFile(Data("[TextureOverride]\nzip = 1\n".utf8),
        to: source.appendingPathComponent("Staged Mod/mod.ini"))
    let archive = root.appendingPathComponent("staged-mod-\(UUID().uuidString).zip")
    try makeZip(source: source, archive: archive)
    let runner = MutatingArchiveSourceRunner(source: archive)
    let store = ModSupportStore(paths: appPaths(root), runner: runner)
    try await store.importMod(from: archive)
    #expect(!FileManager.default.fileExists(atPath: archive.path))
    #expect(try await store.snapshot().mods.map(\.name) == ["Staged Mod"])
}

@Test func repairRollsBackVersionAndManifestWhenManifestPublicationFails() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let ops = FailNextManifestRenameOps(destinationName: "\(fixtureVersion).json")
    let store = ModSupportStore(paths: appPaths(root), fileOps: ops)
    let old = try PackageFixture(root: root, overrides: ["payload/d3d11.dll": Data("old-payload".utf8)])
    try await store.install(manifest: old.manifest(), archive: old.archive)

    let appRoot = appPaths(root).root
    let manifestURL = appRoot.appendingPathComponent("XXMI/Games/starrail/Packages/\(fixtureVersion).json")
    let versionFile = appRoot.appendingPathComponent("XXMI/Versions/\(fixtureVersion)/payload/d3d11.dll")
    let oldManifest = try Data(contentsOf: manifestURL)
    #expect(try Data(contentsOf: versionFile) == Data("old-payload".utf8))

    let repaired = try PackageFixture(root: root, overrides: ["payload/d3d11.dll": Data("new-payload".utf8)])
    ops.arm()
    do {
        try await store.install(manifest: repaired.manifest(), archive: repaired.archive)
        Issue.record("Manifest publication failure was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }

    #expect(try await store.snapshot().installedVersion == fixtureVersion)
    #expect(try Data(contentsOf: versionFile) == Data("old-payload".utf8))
    #expect(try Data(contentsOf: manifestURL) == oldManifest)
}

@Test func committedStateSurvivesStateDirectorySyncFailure() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let ops = FailStateDirectorySyncOps()
    let store = ModSupportStore(paths: appPaths(root), fileOps: ops)
    let package = try PackageFixture(root: root)
    ops.arm()
    try await store.install(manifest: package.manifest(), archive: package.archive)
    #expect(try await store.snapshot().installedVersion == fixtureVersion)
}

@Test func importAndRemovalKeepCommittedStateWhenDirectorySyncFails() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let ops = FailStateDirectorySyncOps()
    let store = ModSupportStore(paths: appPaths(root), fileOps: ops)
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)

    let folder = try makeModFolder(root: root, name: "Committed Mod")
    ops.arm()
    try await store.importMod(from: folder)
    var snapshot = try await store.snapshot()
    #expect(snapshot.mods.count == 1)
    let id = try #require(snapshot.mods.first?.id)
    #expect(FileManager.default.fileExists(atPath: try await store.modsDirectoryURL().appendingPathComponent(id).path))

    ops.arm()
    try await store.removeMod(id: id)
    snapshot = try await store.snapshot()
    #expect(snapshot.mods.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: try await store.modsDirectoryURL().appendingPathComponent(id).path))
}

@Test func copyContentsRejectsExecutableBytesIntroducedAfterValidation() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let folder = try makeModFolder(root: root, name: "Racy Mod")
    let sourceFS = try ContainedFileSystem(root: folder.deletingLastPathComponent())
    let sourcePath = try SafeRelativePath(folder.lastPathComponent)
    let destinationRoot = root.appendingPathComponent("destination-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let destinationFS = try ContainedFileSystem(root: destinationRoot)
    let destination = try SafeRelativePath("mod")
    let sourceData = Data("[TextureOverride]\nhash = fixture\n".utf8)
    var executable = Data([0x4D, 0x5A])
    executable.append(Data(repeating: 0x20, count: max(0, sourceData.count - executable.count)))
    var mutated = false

    do {
        _ = try ModSupportFileSystem.copyContents(from: sourceFS, sourceDirectory: sourcePath,
            to: destinationFS, destinationDirectory: destination, validateModContent: true,
            limit: .mod) { _, path in
                guard !mutated, path.components.last == "mod.ini" else { return }
                mutated = true
                try writeFile(executable, to: folder.appendingPathComponent("mod.ini"))
            }
        Issue.record("Executable bytes copied after source validation were accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }

    #expect(mutated)
    #expect(try Data(contentsOf: destinationRoot.appendingPathComponent("mod/mod.ini")) == executable)
}

private final class MutatingArchiveSourceRunner: ProcessRunner {
    let source: URL
    private let mutated = Mutex(false)

    init(source: URL) { self.source = source }

    func run(_ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?) async throws -> ProcessResult {
        if executable.lastPathComponent == "ditto" {
            let shouldMutate = mutated.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if shouldMutate { try? FileManager.default.removeItem(at: source) }
        }
        return try await SystemProcessRunner().run(executable, arguments: arguments,
            environment: environment, currentDirectory: currentDirectory)
    }
}

private final class FailNextManifestRenameOps: FileOps, @unchecked Sendable {
    private let armed = Mutex(false)
    private let destinationName: String

    init(destinationName: String) {
        self.destinationName = destinationName
    }

    func arm() { armed.withLock { $0 = true } }

    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try SystemFileOps().write(descriptor, bytes: bytes)
    }

    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }

    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        let fail = armed.withLock { value in
            guard value, destination == destinationName else { return false }
            value = false
            return true
        }
        if fail { throw LauncherError.io("Injected metadata rename failure") }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination,
            in: destinationDirectory, exclusive: exclusive)
    }

    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}

private final class FailStateDirectorySyncOps: FileOps, @unchecked Sendable {
    private let armed = Mutex(false)

    func arm() { armed.withLock { $0 = true } }

    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try SystemFileOps().write(descriptor, bytes: bytes)
    }

    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        let fail = armed.withLock { value in
            guard value, let path = Self.path(of: descriptor),
                path.hasSuffix("/XXMI/Games/starrail"),
                FileManager.default.fileExists(atPath: path + "/state.json") else { return false }
            value = false
            return true
        }
        if fail { throw LauncherError.io("Injected state directory sync failure") }
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
