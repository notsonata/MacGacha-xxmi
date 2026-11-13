// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Launch
import LauncherCore
import ModSupport
import Testing
@testable import MacGacha

@Suite(.timeLimit(.minutes(1)))
struct ZZMModSupportTests {
    private nonisolated static var bundledZZZAvailable: Bool {
        Bundle.main.url(forResource: "zzz-zzmi.manifest.json", withExtension: nil,
            subdirectory: "XXMI") != nil
            || Bundle.main.url(forResource: "zzz-zzmi.manifest.json", withExtension: nil) != nil
    }

    @Test(.enabled(if: bundledZZZAvailable)) func loadsTheBundledZZZPackage() async throws {
        let package = try await BundledXXMIPackage.load(gameID: "zzz")
        #expect(package.manifest.id == "zzz-zzmi")
        #expect(package.manifest.gameID == "zzz")
        #expect(package.archiveURL.lastPathComponent == "zzz-zzmi.zip")
    }

    @Test(.enabled(if: bundledZZZAvailable)) @MainActor
    func installingZZZDoesNotTouchStarRailState() async throws {
        let package = try await BundledXXMIPackage.load(gameID: "zzz")
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root), services: PreviewRuntimeServices(),
            defaults: nil, gameServices: PreviewGameServices())
        await model.refreshModSupport(gameID: "zzz")
        #expect(model.modSupportSnapshot(for: "zzz")?.isInstalled == false)
        #expect(model.modSupportSnapshot(for: "starrail") == nil)

        model.installModSupport(package: package, gameID: "zzz")
        await model.modSupportTasks["zzz"]?.value
        #expect(model.modSupportSnapshot(for: "zzz")?.installedVersion == package.manifest.version)
        #expect(model.modSupportSnapshot(for: "starrail") == nil)

        model.setModSupportInjection(true, acknowledgingRisk: true, gameID: "zzz")
        await model.modSupportTasks["zzz"]?.value
        #expect(model.modSupportSnapshot(for: "zzz")?.injectionEnabled == true)
        #expect(model.modSupportSnapshot(for: "starrail") == nil)
    }

    @Test func bundledPackageLookupUsesEachProfilesIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let starRail = root.appendingPathComponent("starrail", isDirectory: true)
        let zzz = root.appendingPathComponent("zzz", isDirectory: true)
        try writePackageFolder(starRail, manifest: try manifest(id: "hsr-srmi", gameID: "starrail",
            version: "2.4.3-macgacha.1"), archiveName: "hsr-srmi.zip")
        try writePackageFolder(zzz, manifest: try manifest(id: "zzz-zzmi", gameID: "zzz",
            version: "1.0.0-macgacha.1"), archiveName: "zzz-zzmi.zip")

        let hsrPackage = try await BundledXXMIPackage.load(directory: starRail)
        let zzzPackage = try await BundledXXMIPackage.load(directory: zzz, gameID: "zzz")
        #expect(hsrPackage.manifest.id == "hsr-srmi")
        #expect(hsrPackage.manifest.gameID == "starrail")
        #expect(zzzPackage.manifest.id == "zzz-zzmi")
        #expect(zzzPackage.manifest.gameID == "zzz")

        await #expect(throws: LauncherError.self) {
            _ = try await BundledXXMIPackage.load(directory: zzz)
        }
    }

    @Test func adapterRefusesZZZDirectX12BeforeCreatingASnapshot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("app", isDirectory: true))
        let store = ModSupportStore(paths: paths, profile: .zzz)
        let package = try makeZZZPackage(root: root)
        try await store.install(manifest: package.manifest, archive: package.archive)
        try await store.setInjectionEnabled(true, acknowledgingRisk: true)
        let backend = try makeBackend(root: root)
        let adapter = ModSupportLaunchAdapter(stores: ["zzz": store])
        let game = try #require(GameDefinition.find("zzz"))

        var settings = LaunchSettings.defaults(for: "zzz")
        #expect(settings.directX12)
        await #expect(throws: LauncherError.self) {
            _ = try await adapter.prepare(game: game, runtimeBundleID: fixtureRuntime,
                backendD3D11: backend, settings: settings)
        }
        await #expect(throws: LauncherError.self) {
            try await adapter.validateEligibility(game: game, settings: settings)
        }
        let sessions = paths.root.appendingPathComponent("XXMI/Sessions/zzz")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: sessions.path))?.isEmpty
            ?? true)

        settings.directX12 = false
        try await adapter.validateEligibility(game: game, settings: settings)
        let configuration = try #require(try await adapter.prepare(game: game,
            runtimeBundleID: fixtureRuntime, backendD3D11: backend, settings: settings))
        #expect(configuration.gameID == "zzz")
        #expect(configuration.resolvedTargetExecutable == "ZenlessZoneZero.exe")
        #expect(configuration.sessionDirectory.path.contains("/XXMI/Sessions/zzz/"))
        #expect(FileManager.default.fileExists(atPath: configuration.runnerURL.path))
    }

    @Test func adapterNeverUsesAnotherGamesStore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("app", isDirectory: true))
        let store = ModSupportStore(paths: paths, profile: .zzz)
        let adapter = ModSupportLaunchAdapter(stores: ["zzz": store])
        let configuration = try await adapter.prepare(game: try #require(GameDefinition.find("genshin")),
            runtimeBundleID: fixtureRuntime, backendD3D11: root.appendingPathComponent("missing"),
            settings: .defaults(for: "genshin"))
        #expect(configuration == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.root.path))
    }
}

private let fixtureRuntime = "d3dmetal-wine11.20-gptk4.0b3"

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZZMModSupportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func manifest(id: String, gameID: String, version: String) throws -> ModPackageManifest {
    ModPackageManifest(id: id, version: version, gameID: gameID,
        supportedRuntimeBundleIDs: [fixtureRuntime], runnerPath: "hook-runner.exe",
        injectorPath: "3dmloader.dll", payloadPath: "payload/d3d11.dll",
        archiveSize: 1, archiveSHA256: String(repeating: "0", count: 64),
        files: [ModPackageFile(path: "hook-runner.exe", size: 1,
            sha256: String(repeating: "0", count: 64))],
        sources: ["zzmi": "1.0"], license: "GPL-3.0-only")
}

private func writePackageFolder(_ folder: URL, manifest: ModPackageManifest,
    archiveName: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    try Data("archive".utf8).write(to: folder.appendingPathComponent(archiveName))
}

private struct ZZPackage {
    let manifest: ModPackageManifest
    let archive: URL
}

private func makeZZZPackage(root: URL) throws -> ZZPackage {
    let source = root.appendingPathComponent("package-source", isDirectory: true)
    let files: [String: Data] = [
        "hook-runner.exe": Data("runner".utf8),
        "3dmloader.dll": Data("injector".utf8),
        "payload/d3d11.dll": Data("payload".utf8),
        "payload/d3dx.ini": Data(("[Loader]\ntarget = Other.exe\nloader = old.exe\n\n"
            + "[System]\nproxy_d3d11 = Z:\\old\\d3d11.dll\n\n[Include]\n"
            + "include_recursive = Mods\n").utf8),
    ]
    for (path, data) in files {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url)
    }
    let archive = root.appendingPathComponent("zzz-zzmi.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-X", "-q", "-r", archive.path, "."]
    process.currentDirectoryURL = source
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let archiveData = try Data(contentsOf: archive)
    let entries = files.keys.sorted().map { path in
        ModPackageFile(path: path, size: Int64(files[path]!.count), sha256: sha256(files[path]!))
    }
    return ZZPackage(manifest: ModPackageManifest(id: "zzz-zzmi", version: "1.0.0-macgacha.1",
        gameID: "zzz", supportedRuntimeBundleIDs: [fixtureRuntime], runnerPath: "hook-runner.exe",
        injectorPath: "3dmloader.dll", payloadPath: "payload/d3d11.dll",
        archiveSize: Int64(archiveData.count), archiveSHA256: sha256(archiveData),
        files: entries, sources: ["zzmi": "1.0"], license: "GPL-3.0-only"), archive: archive)
}

private func makeBackend(root: URL) throws -> URL {
    let url = root.appendingPathComponent("runtime/lib/wine/x86_64-windows/d3d11.dll")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("backend".utf8).write(to: url)
    return url
}

private func sha256(_ data: Data) -> String {
    var hasher = StreamingHasher(.sha256)
    hasher.update(data)
    return hasher.finalize().hex
}
