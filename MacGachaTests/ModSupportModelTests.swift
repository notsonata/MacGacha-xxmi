// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import ModSupport
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor
struct ModSupportModelTests {
    // Binary resources are generated locally and are required for distribution.
    private nonisolated static var bundledPackageAvailable: Bool {
        Bundle.main.url(forResource: "hsr-srmi", withExtension: "zip", subdirectory: "XXMI") != nil
            || Bundle.main.url(forResource: "hsr-srmi", withExtension: "zip") != nil
    }

    @Test(.enabled(if: bundledPackageAvailable)) func installsBundledPackageOfflineAndLeavesInjectionOff() async throws {
        let package = try await BundledXXMIPackage.load()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)

        await model.refreshModSupport()
        #expect(model.modSupportSnapshot?.isInstalled == false)
        #expect(model.modSupportAvailableVersion == package.manifest.version)

        model.installModSupport(package: package)
        await settle(model)

        #expect(model.modSupportSnapshot?.installedVersion == package.manifest.version)
        #expect(model.modSupportSnapshot?.injectionEnabled == false)
        #expect(model.modSupportSnapshot?.riskAcknowledged == false)
        #expect(model.modSupportError == nil)
        #expect(model.modSupportSnapshot?.modsDirectory?.path.hasPrefix(root.path) == true)
    }

    @Test(.enabled(if: bundledPackageAvailable)) func explicitPackageFolderUpdatesWithoutReplacingApp() async throws {
        let package = try await BundledXXMIPackage.load()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("VerifiedPackage", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package.archiveURL, to: folder.appendingPathComponent(BundledXXMIPackage.archiveName))
        try JSONEncoder().encode(package.manifest).write(to: folder.appendingPathComponent(BundledXXMIPackage.manifestName))

        let loaded = try await BundledXXMIPackage.load(directory: folder)
        #expect(loaded.manifest.version == package.manifest.version)
        let model = makeModel(root: root)
        model.importModSupportPackage(from: folder)
        await settle(model)
        #expect(model.modSupportSnapshot?.installedVersion == package.manifest.version)
    }

    @Test(.enabled(if: bundledPackageAvailable)) func firstInjectionEnableRequiresRiskAcknowledgmentThenPersists() async throws {
        let package = try await BundledXXMIPackage.load()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.installModSupport(package: package)
        await settle(model)

        model.setModSupportInjection(true, acknowledgingRisk: false)
        await settle(model)
        #expect(model.modSupportSnapshot?.injectionEnabled == false)
        #expect(model.modSupportSnapshot?.riskAcknowledged == false)
        #expect(model.modSupportError != nil)

        model.setModSupportInjection(true, acknowledgingRisk: true)
        await settle(model)
        #expect(model.modSupportSnapshot?.injectionEnabled == true)
        #expect(model.modSupportSnapshot?.riskAcknowledged == true)

        model.setModSupportInjection(false, acknowledgingRisk: false)
        await settle(model)
        #expect(model.modSupportSnapshot?.injectionEnabled == false)
        #expect(model.modSupportSnapshot?.riskAcknowledged == true)
    }

    @Test func importsChangesSearchesAndPreservesStateOnDuplicateImport() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeModSource(root: root, parent: "First", name: "Alpha Mod")
        let second = try makeModSource(root: root, parent: "Second", name: "Beta Mod")
        let duplicate = try makeModSource(root: root, parent: "Third", name: "Alpha Mod")
        let model = makeModel(root: root)

        model.importModSupport(from: first)
        await settle(model)
        model.importModSupport(from: second)
        await settle(model)
        #expect(model.modSupportSnapshot?.mods.count == 2)
        #expect(model.filteredModSupportMods(matching: "").count == 2)
        #expect(model.filteredModSupportMods(matching: "alpha").map(\.name) == ["Alpha Mod"])
        #expect(model.filteredModSupportMods(matching: "missing").isEmpty)

        let alpha = try #require(model.modSupportSnapshot?.mods.first { $0.name == "Alpha Mod" })
        #expect(alpha.enabled)
        model.setModSupportEnabled(alpha.id, enabled: false)
        await settle(model)
        #expect(model.modSupportSnapshot?.mods.first { $0.id == alpha.id }?.enabled == false)

        model.setModSupportInjection(true, acknowledgingRisk: true)
        await settle(model)
        let before = model.modSupportSnapshot
        model.importModSupport(from: duplicate)
        await settle(model)
        #expect(model.modSupportSnapshot == before)
        #expect(model.modSupportError != nil)
        #expect(model.modSupportSnapshot?.mods.count == 2)
        #expect(model.modSupportSnapshot?.injectionEnabled == true)
        #expect(model.modSupportSnapshot?.riskAcknowledged == true)
    }

    @Test func movesLibraryAndPreservesModsAndSnapshotPath() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeModSource(root: root, parent: "Source", name: "Alpha Mod")
        let model = makeModel(root: root)
        model.importModSupport(from: source)
        await settle(model)
        let imported = try #require(model.modSupportSnapshot?.mods.first)
        model.setModSupportEnabled(imported.id, enabled: false)
        await settle(model)
        let before = try #require(model.modSupportSnapshot)

        let parent = root.appendingPathComponent("Relocated", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("MacGacha-HSR-Mods", isDirectory: true)
        model.moveModSupportDirectory(to: destination)
        await settle(model)

        #expect(model.modSupportError == nil)
        #expect(model.modSupportSnapshot?.modsDirectory?.standardizedFileURL == destination.standardizedFileURL)
        #expect(model.modSupportSnapshot?.mods == before.mods)
        #expect(model.modSupportSnapshot?.mods.first?.enabled == false)
        let relocated = destination.appendingPathComponent(imported.id, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: relocated.path))
    }

    @Test func failedMoveKeepsSnapshotAndShowsAnError() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeModSource(root: root, parent: "Source", name: "Alpha Mod")
        let model = makeModel(root: root)
        model.importModSupport(from: source)
        await settle(model)
        let before = try #require(model.modSupportSnapshot)
        let occupied = root.appendingPathComponent("Occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "existing".write(to: occupied.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)

        model.moveModSupportDirectory(to: occupied)
        await settle(model)

        #expect(model.modSupportError != nil)
        #expect(model.modSupportSnapshot == before)
        #expect(model.modSupportViewState == .ready)
    }

    @Test func failedImportKeepsSnapshotAndShowsAnError() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        await model.refreshModSupport()
        model.importModSupport(from: root.appendingPathComponent("missing-mod"))
        await settle(model)
        #expect(model.modSupportSnapshot?.mods.isEmpty == true)
        #expect(model.modSupportError != nil)
        #expect(model.modSupportViewState == .ready)
    }

    @Test(.enabled(if: bundledPackageAvailable)) func rescansManualFoldersAndReportsUnsafeOnes() async throws {
        let package = try await BundledXXMIPackage.load()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.installModSupport(package: package)
        await settle(model)
        let library = try #require(model.modSupportModsDirectory)
        let safe = library.appendingPathComponent("Firefly", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try "[TextureOverride]\nhash = fixture\n".write(to: safe.appendingPathComponent("mod.ini"),
            atomically: true, encoding: .utf8)
        let unsupported = library.appendingPathComponent("Unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsupported, withIntermediateDirectories: true)
        try "[TextureOverride]\n".write(to: unsupported.appendingPathComponent("mod.ini"),
            atomically: true, encoding: .utf8)
        try Data([0x4D, 0x5A, 0x00, 0x00]).write(to: unsupported.appendingPathComponent("payload.exe"))

        model.rescanModSupportLibrary()
        await settle(model)

        #expect(model.modSupportSnapshot?.mods.map(\.name) == ["Firefly"])
        #expect(model.modSupportError != nil)
        #expect(FileManager.default.fileExists(atPath: unsupported.appendingPathComponent("payload.exe").path))

        model.rescanModSupportLibrary()
        await settle(model)
        #expect(model.modSupportSnapshot?.mods.count == 1)
    }

    @Test func onlyStarRailIsSupported() {
        #expect(AppModel.supportsModSupport(gameID: "starrail"))
        #expect(!AppModel.supportsModSupport(gameID: "starrail-cn"))
        #expect(!AppModel.supportsModSupport(gameID: "genshin"))
        #expect(!AppModel.supportsModSupport(gameID: "zzz"))
    }
}

@MainActor
private func makeModel(root: URL) -> AppModel {
    AppModel(paths: AppPaths(root: root), services: PreviewRuntimeServices(), defaults: nil,
        gameServices: PreviewGameServices())
}

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaModSupportTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeModSource(root: URL, parent: String, name: String) throws -> URL {
    let folder = root.appendingPathComponent(parent, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "[TextureOverride]\nhash = fixture\n".write(to: folder.appendingPathComponent("mod.ini"), atomically: true, encoding: .utf8)
    return folder
}

@MainActor
private func settle(_ model: AppModel) async {
    await model.modSupportTask?.value
}
