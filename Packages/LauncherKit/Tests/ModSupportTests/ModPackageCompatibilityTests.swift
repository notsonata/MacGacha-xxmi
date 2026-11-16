// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
@testable import ModSupport
import Testing

@Test func packageVersionsOrderByUpstreamThenRevision() throws {
    func v(_ text: String) throws -> ModPackageVersion { try #require(ModPackageVersion(text)) }
    #expect(try v("2.4.3-macgacha.4") > v("2.4.3-macgacha.3"))
    #expect(try v("2.4.3-macgacha.10") > v("2.4.3-macgacha.9"))
    #expect(try v("2.5.0-macgacha.1") > v("2.4.3-macgacha.9"))
    #expect(try v("1.10.0-macgacha.1") > v("1.9.9-macgacha.1"))
    #expect(try v("1.5.2-macgacha.2") == v("1.5.2.0-macgacha.2"))
    for text in ["1.5.2-macgacha.2-diag-logging.1", "1.5.2", "1.5.2-beta.1", "a.b.c-macgacha.1", "1.5.2-macgacha.x", ""] {
        #expect(ModPackageVersion(text) == nil, "\(text)")
    }
}

@Test func packageRelationNeverOffersADowngradeAsAnUpdate() {
    #expect(ModPackageRelation.between(installed: nil, bundled: "2.4.3-macgacha.4") == .notInstalled)
    #expect(ModPackageRelation.between(installed: "2.4.3-macgacha.4", bundled: nil) == .noBundledPackage)
    #expect(ModPackageRelation.between(installed: "2.4.3-macgacha.4", bundled: "2.4.3-macgacha.4") == .same)
    #expect(ModPackageRelation.between(installed: "2.4.3-macgacha.3", bundled: "2.4.3-macgacha.4") == .bundledNewer)
    // A newer package imported on its own must not be "updated" back to the built-in one.
    #expect(ModPackageRelation.between(installed: "2.4.3-macgacha.5", bundled: "2.4.3-macgacha.4") == .bundledOlder)
    #expect(ModPackageRelation.between(installed: "1.5.2-macgacha.2-diag-logging.2", bundled: "1.5.2-macgacha.2") == .unknownOrder)
}

private func requiring(_ manifest: ModPackageManifest, minimumAppBuild: Int?) -> ModPackageManifest {
    ModPackageManifest(schemaVersion: manifest.schemaVersion, id: manifest.id, version: manifest.version,
        gameID: manifest.gameID, supportedRuntimeBundleIDs: manifest.supportedRuntimeBundleIDs,
        runnerPath: manifest.runnerPath, injectorPath: manifest.injectorPath, payloadPath: manifest.payloadPath,
        archiveSize: manifest.archiveSize, archiveSHA256: manifest.archiveSHA256, files: manifest.files,
        sources: manifest.sources, license: manifest.license, minimumAppBuild: minimumAppBuild)
}

@Test func installRefusesAPackageThatNeedsANewerApp() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let package = try PackageFixture(root: root)
    let old = ModSupportStore(paths: appPaths(root), fileOps: SystemFileOps(), appBuild: 6)
    do {
        try await old.install(manifest: requiring(package.manifest(), minimumAppBuild: 7), archive: package.archive)
        Issue.record("A package needing build 7 installed on build 6")
    } catch let error as LauncherError {
        guard case .modPackageNeedsNewerApp = error else { throw error }
    }
    #expect(try await old.snapshot().installedVersion == nil)

    // Unknown app builds only accept packages without a minimum.
    let unknown = ModSupportStore(paths: appPaths(root), fileOps: SystemFileOps(), appBuild: nil)
    await #expect(throws: LauncherError.self) {
        try await unknown.install(manifest: requiring(package.manifest(), minimumAppBuild: 1), archive: package.archive)
    }

    let current = ModSupportStore(paths: appPaths(root), fileOps: SystemFileOps(), appBuild: 7)
    try await current.install(manifest: requiring(package.manifest(), minimumAppBuild: 7), archive: package.archive)
    #expect(try await current.snapshot().installedVersion == fixtureVersion)
}

@Test func launchRefusesAnInstalledPackageThatNeedsANewerApp() async throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let package = try PackageFixture(root: root)
    let newer = ModSupportStore(paths: appPaths(root), fileOps: SystemFileOps(), appBuild: 8)
    try await newer.install(manifest: requiring(package.manifest(), minimumAppBuild: 8), archive: package.archive)
    try await newer.setInjectionEnabled(true, acknowledgingRisk: true)
    let backend = try makeBackend(root: root)

    // The same library opened by an older app (for example after a downgrade).
    let older = ModSupportStore(paths: appPaths(root), fileOps: SystemFileOps(), appBuild: 7)
    do {
        _ = try await older.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime, backendD3D11: backend)
        Issue.record("An older app prepared a launch with a package that needs build 8")
    } catch let error as LauncherError {
        guard case .modPackageNeedsNewerApp = error else { throw error }
    }
    #expect(try await newer.prepareLaunch(gameID: "starrail", runtimeBundleID: fixtureRuntime, backendD3D11: backend) != nil)
}

@Test func manifestsWithoutAMinimumKeepTheirEncoding() throws {
    let root = try makeTestRoot(); defer { removeTestRoot(root) }
    let manifest = try PackageFixture(root: root).manifest()
    let encoded = try ModSupportStore.encodeManifest(manifest)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("minimumAppBuild"))
    let decoded = try JSONDecoder().decode(ModPackageManifest.self, from: encoded)
    #expect(decoded.minimumAppBuild == nil)
    #expect(throws: LauncherError.self) { try requiring(manifest, minimumAppBuild: 0).validate() }
}
