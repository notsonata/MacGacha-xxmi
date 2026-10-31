// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport
import Testing

@Test func installRejectsWrongArchiveAndFileHashes() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let package = try PackageFixture(root: root)
    let store = ModSupportStore(paths: appPaths(root))

    do {
        try await store.install(manifest: package.manifest(archiveSHA256: zeroDigest), archive: package.archive)
        Issue.record("Archive digest mismatch was accepted")
    } catch let error as LauncherError {
        guard case .digestMismatch = error else { throw error }
    }
    #expect(try await store.snapshot().installedVersion == nil)

    let badFile = try package.manifest(fileSHA256: ["payload/d3d11.dll": zeroDigest])
    do {
        try await store.install(manifest: badFile, archive: package.archive)
        Issue.record("File digest mismatch was accepted")
    } catch let error as LauncherError {
        guard case .digestMismatch = error else { throw error }
    }
    #expect(try await store.snapshot().installedVersion == nil)

    try await store.install(manifest: package.manifest(), archive: package.archive)
    let snapshot = try await store.snapshot()
    #expect(snapshot.installedVersion == fixtureVersion)
    #expect(snapshot.isInstalled)
}

@Test func installRejectsUndeclaredAndMissingFiles() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let extra = try PackageFixture(root: root, overrides: ["payload/extra.bin": Data("extra".utf8)])
    let store = ModSupportStore(paths: appPaths(root))
    let declared = extra.files.keys.filter { $0 != "payload/extra.bin" }.sorted()
    do {
        try await store.install(manifest: extra.manifest(declaredPaths: declared), archive: extra.archive)
        Issue.record("Undeclared archive file was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }

    let normal = try PackageFixture(root: root)
    let missing = ModPackageFile(path: "payload/missing.bin", size: 1, sha256: zeroDigest)
    do {
        try await store.install(manifest: normal.manifest(
            declaredPaths: normal.files.keys.sorted() + ["payload/missing.bin"], extraFiles: [missing]),
            archive: normal.archive)
        Issue.record("Missing declared file was accepted")
    } catch let error as LauncherError {
        guard case .io = error else { throw error }
    }
    #expect(try await store.snapshot().installedVersion == nil)
}

@Test func repairPreservesModsAndSettingsAndFailedUpdatesKeepPriorVersion() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    let first = try PackageFixture(root: root)
    try await store.install(manifest: first.manifest(), archive: first.archive)

    let mod = try makeModFolder(root: root, name: "Repair Mod")
    try await store.importMod(from: mod)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)

    let repaired = try PackageFixture(root: root,
        overrides: ["payload/d3d11.dll": Data("payload-repaired".utf8)])
    try await store.install(manifest: repaired.manifest(), archive: repaired.archive)
    var snapshot = try await store.snapshot()
    #expect(snapshot.installedVersion == fixtureVersion)
    #expect(snapshot.injectionEnabled)
    #expect(snapshot.riskAcknowledged)
    #expect(snapshot.mods.count == 1)
    #expect(snapshot.mods[0].name == "Repair Mod")
    #expect(snapshot.mods[0].enabled)

    let next = try PackageFixture(root: root, version: "2.4.3-macgacha.2",
        overrides: ["payload/d3d11.dll": Data("payload-next".utf8)])
    do {
        try await store.install(manifest: next.manifest(fileSHA256: ["payload/d3d11.dll": zeroDigest]),
            archive: next.archive)
        Issue.record("Bad update was accepted")
    } catch let error as LauncherError {
        guard case .digestMismatch = error else { throw error }
    }
    snapshot = try await store.snapshot()
    #expect(snapshot.installedVersion == fixtureVersion)
    #expect(snapshot.mods.count == 1)
    #expect(snapshot.injectionEnabled)

    try await store.install(manifest: next.manifest(), archive: next.archive)
    snapshot = try await store.snapshot()
    #expect(snapshot.installedVersion == "2.4.3-macgacha.2")
    #expect(snapshot.mods.count == 1)
    #expect(snapshot.injectionEnabled)
}

@Test func injectionToggleRequiresRiskAcknowledgmentOnce() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let store = ModSupportStore(paths: appPaths(root))
    var snapshot = try await store.snapshot()
    #expect(!snapshot.injectionEnabled)
    #expect(!snapshot.riskAcknowledged)
    #expect(!snapshot.isInstalled)

    do {
        try await store.setInjectionEnabled(true, acknowledgingRisk: false)
        Issue.record("Unacknowledged enable was accepted")
    } catch let error as LauncherError {
        guard case .consentRequired = error else { throw error }
    }
    snapshot = try await store.snapshot()
    #expect(!snapshot.injectionEnabled)

    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    snapshot = try await store.snapshot()
    #expect(snapshot.injectionEnabled)
    #expect(snapshot.riskAcknowledged)

    try await store.setInjectionEnabled(false, acknowledgingRisk: false)
    snapshot = try await store.snapshot()
    #expect(!snapshot.injectionEnabled)
    #expect(snapshot.riskAcknowledged)

    try await store.setInjectionEnabled(true, acknowledgingRisk: false)
    #expect(try await store.snapshot().injectionEnabled)
}
