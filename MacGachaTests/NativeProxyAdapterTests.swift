// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Launch
import LauncherCore
import ModSupport
import Testing
@testable import MacGacha

private let nativeAdapterRuntime = "d3dmetal-wine11.20-gptk4.0b3"

@Suite(.timeLimit(.minutes(1)))
struct NativeProxyAdapterTests {
    @Test func zzzPreparationCarriesNativeModeAndTheSharedSessionDrive() async throws {
        let root = try nativeAdapterRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("app", isDirectory: true))
        let zzz = try await nativeAdapterStore(paths: paths, root: root, profile: .zzz)
        let starRail = try await nativeAdapterStore(paths: paths, root: root, profile: .starRail)
        let adapter = ModSupportLaunchAdapter(stores: ["zzz": zzz, "starrail": starRail])
        let backend = try nativeAdapterBackend(root: root)
        var settings = LaunchSettings.defaults(for: "zzz")
        settings.directX12 = false
        let game = try #require(GameDefinition.find("zzz"))
        let configuration = try #require(try await adapter.prepare(game: game,
            runtimeBundleID: nativeAdapterRuntime, backendD3D11: backend, settings: settings))
        #expect(configuration.loading == .nativeProxy)
        #expect(configuration.gameID == "zzz")
        #expect(configuration.resolvedTargetExecutable == "ZenlessZoneZero.exe")
        #expect(configuration.sessionDirectory.path.contains("/XXMI/Sessions/zzz/"))
        let ini = try String(contentsOf: configuration.sessionDirectory
            .appendingPathComponent("payload/d3dx.ini"), encoding: .utf8)
        let drive = LaunchInjectionConfiguration.sessionDriveLetter
        #expect(ini.contains("user_config = \(drive):\\\(configuration.sessionDirectory.lastPathComponent)"
            + "\\payload\\d3dx_user.ini"))
        // The legacy entry point routes the same game's store and mode.
        let legacy = try #require(try await adapter.prepare(gameID: "zzz",
            runtimeBundleID: nativeAdapterRuntime, backendD3D11: backend))
        #expect(legacy.loading == .nativeProxy)
        #expect(legacy.sessionDirectory.path.contains("/XXMI/Sessions/zzz/"))
    }

    @Test func starRailPreparationStaysImplicitHookRunner() async throws {
        let root = try nativeAdapterRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("app", isDirectory: true))
        let store = try await nativeAdapterStore(paths: paths, root: root, profile: .starRail)
        let adapter = ModSupportLaunchAdapter(store: store)
        let game = try #require(GameDefinition.find("starrail"))
        let configuration = try #require(try await adapter.prepare(
            game: game, runtimeBundleID: nativeAdapterRuntime,
            backendD3D11: try nativeAdapterBackend(root: root), settings: .defaults(for: "starrail")))
        #expect(configuration.loading == nil)
        #expect(configuration.resolvedLoading == .hookRunner)
        #expect(String(data: try JSONEncoder().encode(configuration), encoding: .utf8)?
            .contains("loading") == false)
    }

    @Test func directX12StillBlocksNativeZZZBeforeAnySnapshot() async throws {
        let root = try nativeAdapterRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("app", isDirectory: true))
        let store = try await nativeAdapterStore(paths: paths, root: root, profile: .zzz)
        let adapter = ModSupportLaunchAdapter(stores: ["zzz": store])
        let game = try #require(GameDefinition.find("zzz"))
        let settings = LaunchSettings.defaults(for: "zzz")
        #expect(settings.directX12)
        await #expect(throws: LauncherError.self) {
            try await adapter.validateEligibility(game: game, settings: settings)
        }
        await #expect(throws: LauncherError.self) {
            _ = try await adapter.prepare(game: game, runtimeBundleID: nativeAdapterRuntime,
                backendD3D11: try nativeAdapterBackend(root: root), settings: settings)
        }
        let sessions = paths.root.appendingPathComponent("XXMI/Sessions/zzz")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: sessions.path))?.isEmpty ?? true)
    }
}

private func nativeAdapterRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeProxyAdapterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func nativeAdapterBackend(root: URL) throws -> URL {
    let url = root.appendingPathComponent("runtime/lib/wine/x86_64-windows/d3d11.dll")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("backend".utf8).write(to: url)
    return url
}

/// An installed, enabled synthetic package shaped like the profile's real one.
private func nativeAdapterStore(paths: AppPaths, root: URL, profile: ModSupportProfile) async throws
    -> ModSupportStore {
    let zzz = profile == .zzz
    var files: [String: Data] = [
        "hook-runner.exe": Data("runner".utf8),
        "3dmloader.dll": Data("injector".utf8),
        "payload/d3d11.dll": Data("payload".utf8),
    ]
    if zzz {
        files["payload/d3dcompiler_47.dll"] = Data("compiler".utf8)
        files["payload/Core/ZZMI/main.ini"] = Data("[Constants]\n".utf8)
        files["payload/d3dx.ini"] = Data(("[Loader]\ntarget = ZenlessZoneZero.exe\nloader = hook-runner.exe\n\n"
            + "[Include]\ninclude = Core\\ZZMI\\main.ini\ninclude_recursive = Mods\n\n"
            + "[System]\nproxy_d3d11 =\n\n[Rendering]\noverride_directory = ShaderFixes\n"
            + "cache_directory = ShaderCache\n").utf8)
    } else {
        files["payload/d3dx.ini"] = Data(("[Loader]\ntarget = Other.exe\nloader = old.exe\n\n"
            + "[System]\nproxy_d3d11 = Z:\\old\\d3d11.dll\n\n[Include]\ninclude_recursive = Mods\n").utf8)
    }
    let source = root.appendingPathComponent("package-\(profile.gameID)-\(UUID().uuidString)", isDirectory: true)
    for (path, data) in files {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    let archive = root.appendingPathComponent("\(profile.packageID)-\(UUID().uuidString).zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-X", "-q", "-r", archive.path, "."]
    process.currentDirectoryURL = source
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let archiveData = try Data(contentsOf: archive)
    func digest(_ data: Data) -> String {
        var hasher = StreamingHasher(.sha256)
        hasher.update(data)
        return hasher.finalize().hex
    }
    let manifest = ModPackageManifest(id: profile.packageID, version: "1.0.0-macgacha.1",
        gameID: profile.gameID, supportedRuntimeBundleIDs: [nativeAdapterRuntime],
        runnerPath: "hook-runner.exe", injectorPath: "3dmloader.dll", payloadPath: "payload/d3d11.dll",
        archiveSize: Int64(archiveData.count), archiveSHA256: digest(archiveData),
        files: files.keys.sorted().map { ModPackageFile(path: $0, size: Int64(files[$0]!.count), sha256: digest(files[$0]!)) },
        sources: ["xxmi": "1.0"], license: "GPL-3.0-only")
    let store = ModSupportStore(paths: paths, profile: profile)
    try await store.install(manifest: manifest, archive: archive)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    return store
}
