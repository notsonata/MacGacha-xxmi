// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport
import Testing

@Test func zzzProfileUsesIndependentStorageAndItsExactRunnerTarget() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let starRail = ModSupportStore(paths: paths, profile: .starRail)
    let zzz = ModSupportStore(paths: paths, profile: .zzz)
    let starRailPackage = try PackageFixture(root: root)
    let zzzPackage = try PackageFixture(root: root, version: "1.0.0-macgacha.1",
        gameID: "zzz", packageID: "zzz-zzmi")
    try await starRail.install(manifest: starRailPackage.manifest(), archive: starRailPackage.archive)
    try await zzz.install(manifest: zzzPackage.manifest(), archive: zzzPackage.archive)

    let starRailMod = try makeModFolder(root: root, name: "HSR Mod")
    let zzzMod = try makeModFolder(root: root, name: "ZZZ Mod")
    try await starRail.importMod(from: starRailMod)
    try await zzz.importMod(from: zzzMod)
    try await starRail.setInjectionEnabled(true, acknowledgingRisk: true)
    try await zzz.setInjectionEnabled(true, acknowledgingRisk: true)

    let backend = try makeBackend(root: root)
    let starRailLaunch = try #require(try await starRail.prepareLaunch(gameID: "starrail",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    let zzzLaunch = try #require(try await zzz.prepareLaunch(gameID: "zzz",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend, directX12: false))

    #expect(starRailLaunch.sessionDirectory.path.contains("/XXMI/Sessions/"))
    #expect(!starRailLaunch.sessionDirectory.path.contains("/XXMI/Sessions/starrail/"))
    #expect(zzzLaunch.sessionDirectory.path.contains("/XXMI/Sessions/zzz/"))

    let starRailINI = try String(contentsOf: starRailLaunch.sessionDirectory
        .appendingPathComponent("payload/d3dx.ini"), encoding: .utf8)
    let zzzINI = try String(contentsOf: zzzLaunch.sessionDirectory
        .appendingPathComponent("payload/d3dx.ini"), encoding: .utf8)
    #expect(starRailINI.contains("target = StarRail.exe"))
    #expect(zzzINI.contains("target = ZenlessZoneZero.exe"))

    let starRailMods = try FileManager.default.contentsOfDirectory(
        atPath: starRailLaunch.sessionDirectory.appendingPathComponent("payload/Mods").path)
    let zzzMods = try FileManager.default.contentsOfDirectory(
        atPath: zzzLaunch.sessionDirectory.appendingPathComponent("payload/Mods").path)
    #expect(starRailMods.count == 1)
    #expect(zzzMods.count == 1)
    #expect(starRailMods != zzzMods)
    #expect(try await zzz.snapshot().mods.map(\.name) == ["ZZZ Mod"])
    #expect(try await starRail.snapshot().mods.map(\.name) == ["HSR Mod"])
    #expect(FileManager.default.fileExists(
        atPath: paths.root.appendingPathComponent("XXMI/Games/zzz/state.json").path))
    #expect(FileManager.default.fileExists(
        atPath: paths.root.appendingPathComponent("XXMI/Versions/zzz/1.0.0-macgacha.1").path))
}

@Test func zzzInjectionRefusesDirectX12BeforeCreatingASnapshot() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let zzz = ModSupportStore(paths: paths, profile: .zzz)
    let package = try PackageFixture(root: root, gameID: "zzz", packageID: "zzz-zzmi")
    try await zzz.install(manifest: package.manifest(), archive: package.archive)
    try await zzz.setInjectionEnabled(true, acknowledgingRisk: true)
    let backend = try makeBackend(root: root)

    do {
        _ = try await zzz.prepareLaunch(gameID: "zzz", runtimeBundleID: fixtureRuntime,
            backendD3D11: backend, directX12: true)
        Issue.record("ZZZ injection accepted DirectX 12")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    let sessions = paths.root.appendingPathComponent("XXMI/Sessions/zzz")
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
    #expect(entries.isEmpty)
}

@Test func packagesCannotCrossGamesOrProfiles() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let starRail = ModSupportStore(paths: appPaths(root), profile: .starRail)
    let zzz = ModSupportStore(paths: appPaths(root), profile: .zzz)
    let starRailPackage = try PackageFixture(root: root)
    let zzzPackage = try PackageFixture(root: root, gameID: "zzz", packageID: "zzz-zzmi")
    let zzzWithWrongIdentity = try PackageFixture(root: root, gameID: "zzz", packageID: "hsr-srmi")

    await #expect(throws: LauncherError.self) {
        try await zzz.install(manifest: starRailPackage.manifest(), archive: starRailPackage.archive)
    }
    await #expect(throws: LauncherError.self) {
        try await starRail.install(manifest: zzzPackage.manifest(), archive: zzzPackage.archive)
    }
    await #expect(throws: LauncherError.self) {
        try await zzz.install(manifest: zzzWithWrongIdentity.manifest(),
            archive: zzzWithWrongIdentity.archive)
    }
    #expect(try await zzz.snapshot().isInstalled == false)
    #expect(try await starRail.snapshot().isInstalled == false)
}

@Test func userSettingsStayIsolatedPerGame() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let paths = appPaths(root)
    let starRail = ModSupportStore(paths: paths, profile: .starRail)
    let zzz = ModSupportStore(paths: paths, profile: .zzz)
    let starRailPackage = try PackageFixture(root: root)
    let zzzPackage = try PackageFixture(root: root, gameID: "zzz", packageID: "zzz-zzmi")
    try await starRail.install(manifest: starRailPackage.manifest(), archive: starRailPackage.archive)
    try await zzz.install(manifest: zzzPackage.manifest(), archive: zzzPackage.archive)
    try await starRail.setInjectionEnabled(true, acknowledgingRisk: true)
    try await zzz.setInjectionEnabled(true, acknowledgingRisk: true)
    let backend = try makeBackend(root: root)

    let starRailFirst = try #require(try await starRail.prepareLaunch(gameID: "starrail",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    let zzzFirst = try #require(try await zzz.prepareLaunch(gameID: "zzz",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    try writeFile(Data("HSR user settings\n".utf8),
        to: starRailFirst.sessionDirectory.appendingPathComponent("payload/d3dx_user.ini"))
    try writeFile(Data("ZZZ user settings\n".utf8),
        to: zzzFirst.sessionDirectory.appendingPathComponent("payload/d3dx_user.ini"))
    _ = try await starRail.finishLaunch(sessionDirectory: starRailFirst.sessionDirectory)
    _ = try await zzz.finishLaunch(sessionDirectory: zzzFirst.sessionDirectory)

    let starRailSecond = try #require(try await starRail.prepareLaunch(gameID: "starrail",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    let zzzSecond = try #require(try await zzz.prepareLaunch(gameID: "zzz",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    #expect(try String(contentsOf: starRailSecond.sessionDirectory
        .appendingPathComponent("payload/d3dx_user.ini"), encoding: .utf8) == "HSR user settings\n")
    #expect(try String(contentsOf: zzzSecond.sessionDirectory
        .appendingPathComponent("payload/d3dx_user.ini"), encoding: .utf8) == "ZZZ user settings\n")
}

@Test func hsrProfileKeepsItsExistingBundleTargetAndStorage() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    let backend = try makeBackend(root: root)
    let launch = try #require(try await store.prepareLaunch(gameID: "starrail",
        runtimeBundleID: fixtureRuntime, backendD3D11: backend))
    let ini = try String(contentsOf: launch.sessionDirectory.appendingPathComponent("payload/d3dx.ini"),
        encoding: .utf8)
    #expect(ini.contains("target = StarRail.exe"))
    #expect(launch.sessionDirectory.path.contains("/XXMI/Sessions/"))
    #expect(!launch.sessionDirectory.path.contains("/XXMI/Sessions/starrail/"))
    #expect(FileManager.default.fileExists(
        atPath: appPaths(root).root.appendingPathComponent("XXMI/Games/starrail/state.json").path))
    #expect(FileManager.default.fileExists(
        atPath: appPaths(root).root.appendingPathComponent("XXMI/Versions/\(fixtureVersion)").path))
}
