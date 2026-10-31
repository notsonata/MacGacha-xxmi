// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport
import Testing

@Test func prepareLaunchSnapshotsOnlyEnabledModsAndRewritesPayloadConfig() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let enabledFolder = try makeModFolder(root: root, name: "Enabled Mod")
    let disabledFolder = try makeModFolder(root: root, name: "Disabled Mod")
    try await store.importMod(from: enabledFolder)
    try await store.importMod(from: disabledFolder)
    let before = try await store.snapshot()
    let enabledID = try #require(before.mods.first { $0.name == "Enabled Mod" }?.id)
    let disabledID = try #require(before.mods.first { $0.name == "Disabled Mod" }?.id)
    try await store.setModEnabled(id: disabledID, enabled: false)

    let backend = try makeBackend(root: root)
    #expect(try await store.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime,
        backendD3D11: backend) == nil)

    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    let prepared = try #require(try await store.prepareLaunch(gameID: "starrail",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    let session = prepared.sessionDirectory
    #expect(prepared.runnerURL == session.appendingPathComponent("hook-runner.exe"))
    #expect(prepared.injectorURL == session.appendingPathComponent("3dmloader.dll"))
    #expect(prepared.payloadURL == session.appendingPathComponent("payload/d3d11.dll"))
    #expect(FileManager.default.fileExists(atPath: prepared.runnerURL.path))
    #expect(FileManager.default.fileExists(atPath: prepared.injectorURL.path))
    #expect(FileManager.default.fileExists(atPath: prepared.payloadURL.path))

    let sessionMods = session.appendingPathComponent("payload/Mods")
    let copied = try FileManager.default.contentsOfDirectory(atPath: sessionMods.path).sorted()
    #expect(copied == [enabledID])
    #expect(!FileManager.default.fileExists(atPath: sessionMods.appendingPathComponent(disabledID).path))
    let library = try await store.modsDirectoryURL()
    #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(enabledID).path))
    #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(disabledID).path))

    let expectedBackend = "Z:" + backend.path.replacingOccurrences(of: "/", with: "\\")
    let ini = try String(contentsOf: session.appendingPathComponent("payload/d3dx.ini"), encoding: .utf8)
    #expect(ini.contains("[System]"))
    #expect(ini.contains("proxy_d3d11 = \(expectedBackend)"))
    #expect(ini.contains("target = StarRail.exe"))
    #expect(ini.contains("loader = hook-runner.exe"))
    #expect(ini.contains("include_recursive = Mods"))

    let sessionModINI = sessionMods.appendingPathComponent(enabledID).appendingPathComponent("mod.ini")
    try writeFile(Data("[TextureOverride]\nchanged = 1\n".utf8),
        to: enabledFolder.appendingPathComponent("mod.ini"))
    #expect(try Data(contentsOf: sessionModINI) == Data("[TextureOverride]\nhash = fixture\n".utf8))

    let snapshot = try await store.snapshot()
    #expect(snapshot.injectionEnabled)
    #expect(snapshot.mods.first { $0.id == enabledID }?.enabled == true)
    #expect(snapshot.mods.first { $0.id == disabledID }?.enabled == false)
}

@Test func prepareLaunchRefusesUnsupportedRuntimeAndGame() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    let backend = try makeBackend(root: root)

    do {
        _ = try await store.prepareLaunch(gameID: "starrail", runtimeBundleID: "dxmt-wine11.0",
            backendD3D11: backend)
        Issue.record("Unsupported runtime was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    do {
        _ = try await store.prepareLaunch(gameID: "genshin", runtimeBundleID: fixtureRuntime,
            backendD3D11: backend)
        Issue.record("Unsupported game was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    let sessions = appPaths(root).root.appendingPathComponent("XXMI/Sessions")
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
    #expect(entries.isEmpty)
}

@Test func prepareLaunchFailsClosedWithoutInstallationOrEnabledMods() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    let backend = try makeBackend(root: root)
    do {
        _ = try await store.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime,
            backendD3D11: backend)
        Issue.record("Enabled launch without an installation was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }

    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    let folder = try makeModFolder(root: root, name: "Will Disappear")
    try await store.importMod(from: folder)
    let modID = try #require(try await store.snapshot().mods.first?.id)
    try FileManager.default.removeItem(at: try await store.modsDirectoryURL().appendingPathComponent(modID))
    do {
        _ = try await store.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime,
            backendD3D11: backend)
        Issue.record("Missing enabled mod was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    let versions = appPaths(root).root.appendingPathComponent("XXMI/Versions/\(fixtureVersion)/payload/d3d11.dll")
    try writeFile(Data("hacked!".utf8), to: versions)
    do {
        _ = try await store.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime,
            backendD3D11: backend)
        Issue.record("Tampered installation was accepted")
    } catch let error as LauncherError {
        guard case .digestMismatch = error else { throw error }
    }
    let sessions = appPaths(root).root.appendingPathComponent("XXMI/Sessions")
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
    #expect(entries.isEmpty)
}
