// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import Testing
@testable import ModSupport

private func installedStore(_ root: URL, profile: ModSupportProfile = .starRail) async throws -> ModSupportStore {
    let store = ModSupportStore(paths: appPaths(root), profile: profile)
    let package = try PackageFixture(root: root, gameID: profile.gameID,
        packageID: profile == .zzz ? "zzz-zzmi" : "srmi")
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    return store
}

private func prepare(_ store: ModSupportStore, root: URL, gameID: String = "starrail") async throws -> PreparedModLaunch {
    let backend = try makeBackend(root: root)
    return try #require(try await store.prepareLaunch(gameID: gameID, runtimeBundleID: fixtureRuntime,
        backendD3D11: backend))
}

private func children(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

private func sessionsRoot(_ root: URL, game: String = "starrail") -> URL {
    appPaths(root).root.appendingPathComponent(game == "starrail" ? "XXMI/Sessions" : "XXMI/Sessions/\(game)")
}

private func stagingRoot(_ root: URL, game: String = "starrail") -> URL {
    appPaths(root).root.appendingPathComponent(game == "starrail" ? "XXMI/.staging" : "XXMI/.staging/\(game)")
}

private func canonicalUUIDs(_ names: [String]) -> [String] {
    names.filter { UUID(uuidString: $0)?.uuidString == $0 }
}

private func userConfigURL(_ prepared: PreparedModLaunch) -> URL {
    prepared.sessionDirectory.appendingPathComponent("payload/d3dx_user.ini")
}

@Suite(.timeLimit(.minutes(1))) struct ModSupportSessionLifecycleTests {
    @Test func repeatedPrepareFinishCyclesLeaveNoSessionDirectories() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = try await installedStore(root)
        try await store.importMod(from: makeModFolder(root: root, name: "Body"))
        for _ in 0..<5 {
            let prepared = try await prepare(store, root: root)
            #expect(FileManager.default.fileExists(atPath: prepared.sessionDirectory.path))
            _ = try await store.finishLaunch(sessionDirectory: prepared.sessionDirectory)
        }
        await store.drainReclamation()
        #expect(canonicalUUIDs(children(sessionsRoot(root))).isEmpty)
        #expect(children(stagingRoot(root)).filter { $0.hasPrefix("reclaim-") }.isEmpty)
        #expect(await store.reclamationFailureCount() == 0)
    }

    @Test func finishHarvestsSettingsBeforeReclaimingAndRepeatsSafely() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = try await installedStore(root)
        let first = try await prepare(store, root: root)
        let settings = Data("$costume_mods = 0\r\n".utf8)
        try writeFile(settings, to: userConfigURL(first))
        #expect(try await store.finishLaunch(sessionDirectory: first.sessionDirectory) == .stored)
        #expect(!FileManager.default.fileExists(atPath: first.sessionDirectory.path))
        // verifiedEnd may run finish again when its endLogged checkpoint failed.
        #expect(try await store.finishLaunch(sessionDirectory: first.sessionDirectory) == .alreadyFinished)
        let second = try await prepare(store, root: root)
        #expect(try Data(contentsOf: userConfigURL(second)) == settings)
    }

    @Test func unchangedSupersededAndUnpreparedSessionsAreReclaimed() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = try await installedStore(root)
        let older = try await prepare(store, root: root)
        let newer = try await prepare(store, root: root)
        try writeFile(Data("$a = 1\r\n".utf8), to: userConfigURL(newer))
        #expect(try await store.finishLaunch(sessionDirectory: newer.sessionDirectory) == .stored)
        try writeFile(Data("$a = 0\r\n".utf8), to: userConfigURL(older))
        #expect(try await store.finishLaunch(sessionDirectory: older.sessionDirectory) == .superseded)
        let unchanged = try await prepare(store, root: root)
        #expect(try await store.finishLaunch(sessionDirectory: unchanged.sessionDirectory) == .unchanged)
        let unprepared = try await prepare(store, root: root)
        try FileManager.default.removeItem(at: unprepared.sessionDirectory.appendingPathComponent(".macgacha-session.json"))
        #expect(try await store.finishLaunch(sessionDirectory: unprepared.sessionDirectory) == .notPrepared)
        for prepared in [older, newer, unchanged, unprepared] {
            #expect(!FileManager.default.fileExists(atPath: prepared.sessionDirectory.path))
        }
    }

    @Test func harvestFailureRetainsTheSessionForRetry() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let ops = SessionFaultOps()
        let store = ModSupportStore(paths: appPaths(root), fileOps: ops)
        let package = try PackageFixture(root: root)
        try await store.install(manifest: package.manifest(), archive: package.archive)
        try await store.setInjectionEnabled(true, acknowledgingRisk: true)
        let prepared = try await prepare(store, root: root)
        let settings = Data("$costume_mods = 1\r\n".utf8)
        try writeFile(settings, to: userConfigURL(prepared))
        ops.failRenames(matching: "d3dx-user.json")
        await #expect(throws: LauncherError.self) {
            try await store.finishLaunch(sessionDirectory: prepared.sessionDirectory)
        }
        #expect(FileManager.default.fileExists(atPath: userConfigURL(prepared).path))
        ops.reset()
        #expect(try await store.finishLaunch(sessionDirectory: prepared.sessionDirectory) == .stored)
        #expect(!FileManager.default.fileExists(atPath: prepared.sessionDirectory.path))
        let next = try await prepare(store, root: root)
        #expect(try Data(contentsOf: userConfigURL(next)) == settings)
    }

    @Test func reclamationFailureIsObservableAndRetried() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let ops = SessionFaultOps()
        let store = ModSupportStore(paths: appPaths(root), fileOps: ops)
        let package = try PackageFixture(root: root)
        try await store.install(manifest: package.manifest(), archive: package.archive)
        try await store.setInjectionEnabled(true, acknowledgingRisk: true)
        let prepared = try await prepare(store, root: root)
        ops.failUnlinks(matching: "hook-runner.exe")
        #expect(try await store.finishLaunch(sessionDirectory: prepared.sessionDirectory) == .unchanged)
        await store.drainReclamation()
        #expect(await store.reclamationFailureCount() == 1)
        #expect(!children(stagingRoot(root)).filter { $0.hasPrefix("reclaim-") }.isEmpty)
        ops.reset()
        // The next store-owned launch retries leftover trash.
        let next = try await prepare(store, root: root)
        await store.drainReclamation()
        #expect(children(stagingRoot(root)).filter { $0.hasPrefix("reclaim-") }.isEmpty)
        #expect(await store.reclamationFailureCount() == 0)
        #expect(FileManager.default.fileExists(atPath: next.sessionDirectory.path))
    }

    @Test func reclamationIgnoresCancellationAndTheEntryBudget() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let base = appPaths(root).root
        let tree = base.appendingPathComponent("tree", isDirectory: true)
        let wide = tree.appendingPathComponent("wide", isDirectory: true)
        try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: true)
        // A single directory larger than one batch, and a nested symlink that
        // must be unlinked rather than followed.
        let directory = Darwin.open(wide.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directory >= 0)
        for index in 0..<100_050 {
            let fd = openat(directory, "f\(index)", O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
            if fd >= 0 { Darwin.close(fd) }
        }
        Darwin.close(directory)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("link"), withDestinationURL: outside)
        let fs = try ContainedFileSystem(root: base)
        // The ordinary removal refuses a tree beyond its per-operation budget.
        #expect(throws: LauncherError.self) { try fs.removeItem(at: SafeRelativePath("tree")) }
        #expect(FileManager.default.fileExists(atPath: wide.path))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try fs.removeTreeInBatches(at: SafeRelativePath("tree"))
        }
        try await task.value
        #expect(!FileManager.default.fileExists(atPath: tree.path))
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    }

    @Test func failedPreparationsAndDiscardsLeaveNoSession() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = try await installedStore(root)
        try await store.importMod(from: makeModFolder(root: root, name: "Body"))
        let libraryMod = appPaths(root).root.appendingPathComponent("XXMI/Games/starrail/Mods")
        let modFolder = try #require(children(libraryMod).first)
        try FileManager.default.removeItem(at: libraryMod.appendingPathComponent(modFolder))
        await #expect(throws: LauncherError.self) { try await prepare(store, root: root) }
        await store.drainReclamation()
        #expect(canonicalUUIDs(children(sessionsRoot(root))).isEmpty)

        let refreshed = try await store.refreshModLibrary()
        #expect(refreshed.changed)
        let prepared = try await prepare(store, root: root)
        await store.discardLaunch(sessionDirectory: prepared.sessionDirectory)
        await store.drainReclamation()
        #expect(!FileManager.default.fileExists(atPath: prepared.sessionDirectory.path))
        #expect(children(stagingRoot(root)).filter { $0.hasPrefix("reclaim-") }.isEmpty)
    }

    @Test func sweepRemovesOnlyUnretainedCanonicalSessionsPerGame() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let starRail = try await installedStore(root)
        let zzz = try await installedStore(root, profile: .zzz)
        let retained = try await prepare(starRail, root: root)
        let orphan = try await prepare(starRail, root: root)
        let zzzOrphan = try await prepare(zzz, root: root, gameID: "zzz")
        let foreign = sessionsRoot(root).appendingPathComponent("not-a-session", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let lowercase = sessionsRoot(root).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: lowercase, withIntermediateDirectories: true)
        let staleLive = stagingRoot(root).appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleLive, withIntermediateDirectories: true)
        let unrelatedStaging = stagingRoot(root).appendingPathComponent("install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unrelatedStaging, withIntermediateDirectories: true)

        let report = await starRail.sweepSessions(retaining: [retained.sessionDirectory])
        await starRail.drainReclamation()
        #expect(report.reclaimed == 2)
        #expect(report.failed == 0)
        #expect(FileManager.default.fileExists(atPath: retained.sessionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.sessionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: staleLive.path))
        // HSR's sweep never enters Sessions/zzz or touches non-canonical names.
        #expect(FileManager.default.fileExists(atPath: zzzOrphan.sessionDirectory.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(FileManager.default.fileExists(atPath: lowercase.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedStaging.path))

        _ = await zzz.sweepSessions(retaining: [])
        await zzz.drainReclamation()
        #expect(!FileManager.default.fileExists(atPath: zzzOrphan.sessionDirectory.path))
        #expect(FileManager.default.fileExists(atPath: retained.sessionDirectory.path))
    }

    @Test func finishRejectsAnotherProfilesSession() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let starRail = try await installedStore(root)
        let zzz = try await installedStore(root, profile: .zzz)
        let zzzSession = try await prepare(zzz, root: root, gameID: "zzz")
        await #expect(throws: LauncherError.self) {
            try await starRail.finishLaunch(sessionDirectory: zzzSession.sessionDirectory)
        }
        await #expect(throws: LauncherError.self) {
            try await starRail.finishLaunch(sessionDirectory: sessionsRoot(root, game: "zzz"))
        }
        #expect(FileManager.default.fileExists(atPath: zzzSession.sessionDirectory.path))
    }
}

/// Fails renames or unlinks of one leaf name until reset.
final class SessionFaultOps: FileOps, @unchecked Sendable {
    private let lock = NSLock()
    private var renameName: String?
    private var unlinkName: String?

    func failRenames(matching name: String) { lock.withLock { renameName = name } }
    func failUnlinks(matching name: String) { lock.withLock { unlinkName = name } }
    func reset() { lock.withLock { renameName = nil; unlinkName = nil } }

    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        if lock.withLock({ renameName == destination }) { throw LauncherError.io("injected rename failure") }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination,
            in: destinationDirectory, exclusive: exclusive)
    }
    func swap(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32) throws {
        if lock.withLock({ renameName == destination }) { throw LauncherError.io("injected swap failure") }
        try SystemFileOps().swap(from: source, in: sourceDirectory, to: destination, in: destinationDirectory)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        if lock.withLock({ unlinkName == name }) { throw LauncherError.io("injected unlink failure") }
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}

private func sessionMods(_ prepared: PreparedModLaunch) -> URL {
    prepared.sessionDirectory.appendingPathComponent("payload/Mods", isDirectory: true)
}

private func liveLeftovers(_ root: URL) -> [String] {
    children(stagingRoot(root)).filter { $0.hasPrefix("live-") || $0.hasPrefix("reclaim-") }
}

@Suite(.timeLimit(.minutes(1))) struct ModSupportLiveApplyTests {
    @Test func applyPublishesTheCompleteEnabledSetIntoModsOnly() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = try await installedStore(root)
        try await store.importMod(from: makeModFolder(root: root, name: "Body"))
        let prepared = try await prepare(store, root: root)
        let d3dx = prepared.sessionDirectory.appendingPathComponent("payload/d3dx.ini")
        let d3dxBefore = try Data(contentsOf: d3dx)
        try writeFile(Data("$x = 1\r\n".utf8), to: userConfigURL(prepared))
        let body = try #require(await store.snapshot().mods.first)
        #expect(children(sessionMods(prepared)) == [body.id])

        // Add, edit, disable and remove in the library, then apply explicitly.
        try await store.importMod(from: makeModFolder(root: root, name: "Hair",
            extra: ["extra.ini": Data("[Extra]\n".utf8)]))
        let hair = try #require(await store.snapshot().mods.first { $0.name == "Hair" })
        let library = appPaths(root).root.appendingPathComponent("XXMI/Games/starrail/Mods")
        try Data("[Edited]\n".utf8).write(to: library.appendingPathComponent("\(hair.folderPath)/mod.ini"))
        try await store.setModEnabled(id: body.id, enabled: false)
        let result = try await store.applyLiveMods(sessionDirectory: prepared.sessionDirectory)
        await store.drainReclamation()
        #expect(result.enabledMods == 1)
        #expect(children(sessionMods(prepared)) == [hair.id])
        #expect(try Data(contentsOf: sessionMods(prepared).appendingPathComponent("\(hair.id)/mod.ini"))
            == Data("[Edited]\n".utf8))
        #expect(try Data(contentsOf: d3dx) == d3dxBefore)
        #expect(try Data(contentsOf: userConfigURL(prepared)) == Data("$x = 1\r\n".utf8))
        #expect(liveLeftovers(root).isEmpty)

        try await store.removeMod(id: hair.id)
        _ = try await store.applyLiveMods(sessionDirectory: prepared.sessionDirectory)
        #expect(children(sessionMods(prepared)).isEmpty)
        // The settings harvest still works after a live apply.
        #expect(try await store.finishLaunch(sessionDirectory: prepared.sessionDirectory) == .stored)
        await store.drainReclamation()
        #expect(!FileManager.default.fileExists(atPath: prepared.sessionDirectory.path))
        #expect(liveLeftovers(root).isEmpty)
    }

    @Test func unsafeLibraryContentKeepsThePreviousCompleteTree() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = try await installedStore(root)
        try await store.importMod(from: makeModFolder(root: root, name: "Body"))
        let prepared = try await prepare(store, root: root)
        let before = children(sessionMods(prepared))
        let mod = try #require(await store.snapshot().mods.first)
        let folder = appPaths(root).root.appendingPathComponent("XXMI/Games/starrail/Mods/\(mod.folderPath)")

        try Data("MZ".utf8).write(to: folder.appendingPathComponent("tool.bin"))
        await #expect(throws: LauncherError.self) {
            try await store.applyLiveMods(sessionDirectory: prepared.sessionDirectory)
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("tool.bin"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"),
            withDestinationURL: root)
        await #expect(throws: LauncherError.self) {
            try await store.applyLiveMods(sessionDirectory: prepared.sessionDirectory)
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("escape"))
        try FileManager.default.removeItem(at: folder)
        await #expect(throws: LauncherError.self) {
            try await store.applyLiveMods(sessionDirectory: prepared.sessionDirectory)
        }
        await store.drainReclamation()
        #expect(children(sessionMods(prepared)) == before)
        #expect(FileManager.default.fileExists(atPath: sessionMods(prepared)
            .appendingPathComponent("\(mod.id)/mod.ini").path))
        #expect(liveLeftovers(root).isEmpty)
    }

    @Test func publicationFailureKeepsThePreviousTree() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let ops = SessionFaultOps()
        let store = ModSupportStore(paths: appPaths(root), fileOps: ops)
        let package = try PackageFixture(root: root)
        try await store.install(manifest: package.manifest(), archive: package.archive)
        try await store.setInjectionEnabled(true, acknowledgingRisk: true)
        try await store.importMod(from: makeModFolder(root: root, name: "Body"))
        let prepared = try await prepare(store, root: root)
        let before = children(sessionMods(prepared))
        try await store.importMod(from: makeModFolder(root: root, name: "Hair"))
        ops.failRenames(matching: "Mods")
        await #expect(throws: LauncherError.self) {
            try await store.applyLiveMods(sessionDirectory: prepared.sessionDirectory)
        }
        ops.reset()
        await store.drainReclamation()
        #expect(children(sessionMods(prepared)) == before)
        #expect(liveLeftovers(root).isEmpty)
    }

    @Test func missingCustomLibraryFailsClosed() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = try await installedStore(root)
        try await store.importMod(from: makeModFolder(root: root, name: "Body"))
        let prepared = try await prepare(store, root: root)
        let before = children(sessionMods(prepared))
        let custom = root.appendingPathComponent("custom-library/Mods", isDirectory: true)
        try FileManager.default.createDirectory(at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await store.moveModsDirectory(to: custom)
        try FileManager.default.removeItem(at: custom)
        await #expect(throws: LauncherError.self) {
            try await store.applyLiveMods(sessionDirectory: prepared.sessionDirectory)
        }
        #expect(children(sessionMods(prepared)) == before)
        #expect(!FileManager.default.fileExists(atPath: custom.path))
    }

    @Test func applyRejectsFinishedForeignAndOutsideSessions() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let starRail = try await installedStore(root)
        let zzz = try await installedStore(root, profile: .zzz)
        let zzzSession = try await prepare(zzz, root: root, gameID: "zzz")
        await #expect(throws: LauncherError.self) {
            try await starRail.applyLiveMods(sessionDirectory: zzzSession.sessionDirectory)
        }
        let outside = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        await #expect(throws: LauncherError.self) {
            try await starRail.applyLiveMods(sessionDirectory: outside)
        }
        // A ZZZ session routes to the ZZZ store and its own Mods tree.
        _ = try await zzz.applyLiveMods(sessionDirectory: zzzSession.sessionDirectory)
        let finished = try await prepare(starRail, root: root)
        _ = try await starRail.finishLaunch(sessionDirectory: finished.sessionDirectory)
        await #expect(throws: LauncherError.self) {
            try await starRail.applyLiveMods(sessionDirectory: finished.sessionDirectory)
        }
        let unmarked = try await prepare(starRail, root: root)
        try FileManager.default.removeItem(at: unmarked.sessionDirectory.appendingPathComponent(".macgacha-session.json"))
        await #expect(throws: LauncherError.self) {
            try await starRail.applyLiveMods(sessionDirectory: unmarked.sessionDirectory)
        }
    }

    @Test func applyAndFinishRacingLeaveNothingBehind() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = try await installedStore(root)
        try await store.importMod(from: makeModFolder(root: root, name: "Body"))
        for _ in 0..<3 {
            let prepared = try await prepare(store, root: root)
            async let apply: ModLiveApplyResult? = try? store.applyLiveMods(sessionDirectory: prepared.sessionDirectory)
            async let finish = store.finishLaunch(sessionDirectory: prepared.sessionDirectory)
            _ = await apply
            _ = try await finish
            await store.drainReclamation()
            #expect(!FileManager.default.fileExists(atPath: prepared.sessionDirectory.path))
        }
        #expect(canonicalUUIDs(children(sessionsRoot(root))).isEmpty)
        #expect(liveLeftovers(root).isEmpty)
    }
}
