// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport
import Testing

private func prepareInjectedLaunch(_ store: ModSupportStore, root: URL) async throws -> PreparedModLaunch {
    let backend = try makeBackend(root: root)
    let prepared = try await store.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime,
        backendD3D11: backend)
    return try #require(prepared)
}

private func userConfigURL(_ prepared: PreparedModLaunch) -> URL {
    prepared.sessionDirectory.appendingPathComponent("payload/d3dx_user.ini")
}

@Test func launchSnapshotsSeedAndHarvestSRMIUserSettings() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)

    let first = try await prepareInjectedLaunch(store, root: root)
    #expect(!FileManager.default.fileExists(atPath: userConfigURL(first).path))
    let settings = Data("[Constants]\r\n$costume_mods = 0\r\n".utf8)
    try writeFile(settings, to: userConfigURL(first))
    #expect(try await store.finishLaunch(sessionDirectory: first.sessionDirectory) == .stored)

    let second = try await prepareInjectedLaunch(store, root: root)
    #expect(try Data(contentsOf: userConfigURL(second)) == settings)
    try writeFile(settings, to: userConfigURL(second))
    #expect(try await store.finishLaunch(sessionDirectory: second.sessionDirectory) == .unchanged)

    let third = try await prepareInjectedLaunch(store, root: root)
    #expect(try Data(contentsOf: userConfigURL(third)) == settings)
}

@Test func clearingUserSettingsIsRememberedForLaterLaunches() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)

    let first = try await prepareInjectedLaunch(store, root: root)
    try writeFile(Data("$costume_mods = 1\r\n".utf8), to: userConfigURL(first))
    #expect(try await store.finishLaunch(sessionDirectory: first.sessionDirectory) == .stored)

    let second = try await prepareInjectedLaunch(store, root: root)
    #expect(FileManager.default.fileExists(atPath: userConfigURL(second).path))
    try FileManager.default.removeItem(at: userConfigURL(second))
    #expect(try await store.finishLaunch(sessionDirectory: second.sessionDirectory) == .stored)

    let third = try await prepareInjectedLaunch(store, root: root)
    #expect(!FileManager.default.fileExists(atPath: userConfigURL(third).path))
}

@Test func staleOlderSessionCannotOverwriteNewerUserSettings() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let package = try PackageFixture(root: root)
    try await store.install(manifest: package.manifest(), archive: package.archive)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)

    let older = try await prepareInjectedLaunch(store, root: root)
    let newer = try await prepareInjectedLaunch(store, root: root)
    let olderSettings = Data("$costume_mods = 0\r\n".utf8)
    let newerSettings = Data("$costume_mods = 1\r\n".utf8)
    try writeFile(newerSettings, to: userConfigURL(newer))
    #expect(try await store.finishLaunch(sessionDirectory: newer.sessionDirectory) == .stored)
    try writeFile(olderSettings, to: userConfigURL(older))
    #expect(try await store.finishLaunch(sessionDirectory: older.sessionDirectory) == .superseded)

    let next = try await prepareInjectedLaunch(store, root: root)
    #expect(try Data(contentsOf: userConfigURL(next)) == newerSettings)
}

@Test func finishRejectsSessionsOutsideTheManagedSessionsDirectory() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let outside = root.appendingPathComponent("outside-session", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try writeFile(Data("$costume_mods = 1\r\n".utf8), to: outside.appendingPathComponent("payload/d3dx_user.ini"))

    await #expect(throws: LauncherError.self) {
        try await store.finishLaunch(sessionDirectory: outside)
    }
    let userRoot = appPaths(root).root.appendingPathComponent("XXMI/Games/starrail/User")
    #expect(!FileManager.default.fileExists(atPath: userRoot.appendingPathComponent("d3dx-user.json").path))
}
