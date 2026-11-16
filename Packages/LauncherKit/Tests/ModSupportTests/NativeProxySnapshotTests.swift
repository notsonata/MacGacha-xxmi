// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import Testing
@testable import ModSupport

/// Mirrors the shipped ZZMI `d3dx.ini` sections native loading depends on.
private let nativeINI = "; zzmi fixture\n[Loader]\ntarget = Z:\\old\\ZenlessZoneZero.exe\n"
    + "loader = hook-runner.exe\nmodule = d3d11.dll\nrequire_admin = true\n"
    + "check_target_even_without_loader = 1\n[Include]\ninclude = Core\\ZZMI\\main.ini\n"
    + "include_recursive = Mods\nexclude_recursive = DISABLED*\n\n[System]\n"
    + "skip_early_includes_load = 1\nproxy_d3d11 = Z:\\old\\d3d11.dll\n\n[Device]\nsettings_auto_save_interval = 60\n\n"
    + "[Rendering]\noverride_directory = ShaderFixes\ncache_directory = ShaderCache\n\n"
    + "[Logging]\nlog_level = info\n"

private func nativeFiles(ini: String = nativeINI, without: Set<String> = []) -> [String: Data] {
    var files = [
        "payload/d3dcompiler_47.dll": Data("compiler".utf8),
        "payload/Core/ZZMI/main.ini": Data("[Constants]\nglobal $zzmi = 1\n".utf8),
        "payload/ShaderFixes/readme.txt": Data("fixes".utf8),
        "payload/d3dx.ini": Data(ini.utf8),
    ]
    for path in without { files.removeValue(forKey: path) }
    return files
}

private func zzzStore(_ root: URL, overrides: [String: Data] = nativeFiles(),
    removing: Set<String> = []) async throws -> (ModSupportStore, PackageFixture) {
    let store = ModSupportStore(paths: appPaths(root), profile: .zzz)
    let package = try PackageFixture(root: root, gameID: "zzz", packageID: "zzz-zzmi", overrides: overrides)
    var declared: [String]?
    if !removing.isEmpty {
        // PackageFixture always writes its base files; rezip and declare without them.
        let source = root.appendingPathComponent("package-trimmed-\(UUID().uuidString)", isDirectory: true)
        for (path, data) in package.files where !removing.contains(path) {
            try writeFile(data, to: source.appendingPathComponent(path))
        }
        try makeZip(source: source, archive: package.archive)
        declared = package.files.keys.filter { !removing.contains($0) }.sorted()
    }
    try await store.install(manifest: package.manifest(declaredPaths: declared), archive: package.archive)
    try await store.setInjectionEnabled(true, acknowledgingRisk: true)
    return (store, package)
}

private func sessions(_ root: URL) -> [String] {
    let url = appPaths(root).root.appendingPathComponent("XXMI/Sessions/zzz")
    return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
        .filter { UUID(uuidString: $0)?.uuidString == $0 }
}

/// Active `key = value` entries of one section, in file order.
private func entries(_ text: String, _ section: String) -> [(String, String)] {
    var current: String?
    var result: [(String, String)] = []
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { current = String(line.dropFirst().prefix { $0 != "]" }); continue }
        guard current == section, !line.hasPrefix(";"), let equals = line.firstIndex(of: "=") else { continue }
        result.append((line[..<equals].trimmingCharacters(in: .whitespaces),
            line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)))
    }
    return result
}

private func value(_ text: String, _ section: String, _ key: String) -> [String] {
    entries(text, section).filter { $0.0 == key }.map(\.1)
}

private func prepareZZZ(_ store: ModSupportStore, root: URL, directX12: Bool = false,
    letter: String = "M") async throws -> PreparedModLaunch {
    try #require(try await store.prepareLaunch(gameID: "zzz", runtimeBundleID: fixtureRuntime,
        backendD3D11: try makeBackend(root: root), directX12: directX12, sessionDriveLetter: letter))
}

@Suite(.timeLimit(.minutes(1))) struct NativeProxySnapshotTests {
    @Test func profilesChooseTheirLoadingModes() {
        #expect(ModSupportProfile.zzz.loadingMode == .nativeProxy)
        #expect(ModSupportProfile.starRail.loadingMode == .hookRunner)
    }

    @Test func nativeINIUsesThisSessionsDrivePathsAndEveryRequiredKey() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let (store, _) = try await zzzStore(root)
        try await store.importMod(from: makeModFolder(root: root, name: "Belle"))
        let prepared = try await prepareZZZ(store, root: root)
        #expect(prepared.loadingMode == .nativeProxy)
        let session = prepared.sessionDirectory.lastPathComponent
        #expect(UUID(uuidString: session)?.uuidString == session)
        let ini = try String(contentsOf: prepared.sessionDirectory.appendingPathComponent("payload/d3dx.ini"),
            encoding: .utf8)
        let base = "M:\\\(session)\\payload"
        let backend = try makeBackend(root: root)
        #expect(value(ini, "Loader", "target") == ["ZenlessZoneZero.exe"])
        #expect(value(ini, "Loader", "check_target_even_without_loader") == ["1"])
        #expect(value(ini, "Loader", "loader") == ["hook-runner.exe"])
        #expect(value(ini, "System", "proxy_d3d11") == ["Z:" + backend.path.replacingOccurrences(of: "/", with: "\\")])
        #expect(value(ini, "Include", "user_config") == [base + "\\d3dx_user.ini"])
        #expect(value(ini, "Include", "include") == ["Core\\ZZMI\\main.ini"])
        #expect(value(ini, "Include", "include_recursive") == ["Mods"])
        #expect(value(ini, "Rendering", "override_directory") == [base + "\\ShaderFixes"])
        #expect(value(ini, "Rendering", "cache_directory") == [base + "\\ShaderCache"])
        // The synthetic-only session-less path is never rendered.
        #expect(!ini.contains("M:\\payload"))
        // Core and mod includes load before the game creates buffers, so the
        // shipped deferral is switched off in this session copy only.
        #expect(value(ini, "System", "skip_early_includes_load") == ["0"])
        // Logging, autosave and other shipped defaults are untouched.
        #expect(value(ini, "Logging", "log_level") == ["info"])
        #expect(value(ini, "Device", "settings_auto_save_interval") == ["60"])
        #expect(value(ini, "Loader", "require_admin") == ["true"])
        #expect(value(ini, "Include", "exclude_recursive") == ["DISABLED*"])
        #expect(ini.hasPrefix("; zzmi fixture\n[Loader]\ntarget = ZenlessZoneZero.exe\n"))
        // Every key is edited in place: no section or key is duplicated.
        #expect(ini.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
            == ["[Loader]", "[Include]", "[System]", "[Device]", "[Rendering]", "[Logging]"])
        // The snapshot's mods and the installed source are unchanged otherwise.
        let mods = try FileManager.default.contentsOfDirectory(
            atPath: prepared.sessionDirectory.appendingPathComponent("payload/Mods").path)
        #expect(mods.count == 1)
        let installed = appPaths(root).root.appendingPathComponent(
            "XXMI/Versions/zzz/\(fixtureVersion)/payload/d3dx.ini")
        #expect(try Data(contentsOf: installed) == Data(nativeINI.utf8))
        // The pinned package keeps its own deferral of early includes.
        #expect(value(nativeINI, "System", "skip_early_includes_load") == ["1"])
    }

    @Test func missingDeferralKeyIsAddedOnceAsZero() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let bare = nativeINI.replacingOccurrences(of: "skip_early_includes_load = 1\n", with: "")
        let (store, _) = try await zzzStore(root, overrides: nativeFiles(ini: bare))
        let prepared = try await prepareZZZ(store, root: root)
        let ini = try String(contentsOf: prepared.sessionDirectory.appendingPathComponent("payload/d3dx.ini"),
            encoding: .utf8)
        #expect(value(ini, "System", "skip_early_includes_load") == ["0"])
        #expect(ini.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count == 6)
    }

    @Test func crlfPackageIsEditedPerLineAndKeepsItsLineEndings() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let crlf = nativeINI.replacingOccurrences(of: "\n", with: "\r\n")
        let (store, _) = try await zzzStore(root, overrides: nativeFiles(ini: crlf))
        let prepared = try await prepareZZZ(store, root: root)
        let ini = try String(contentsOf: prepared.sessionDirectory.appendingPathComponent("payload/d3dx.ini"),
            encoding: .utf8)
        #expect(!ini.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(value(ini, "Loader", "target") == ["ZenlessZoneZero.exe"])
        #expect(value(ini, "System", "skip_early_includes_load") == ["0"])
        #expect(value(ini, "Rendering", "cache_directory")
            == ["M:\\\(prepared.sessionDirectory.lastPathComponent)\\payload\\ShaderCache"])
        #expect(ini.components(separatedBy: "\r\n").filter { $0.hasPrefix("[") }.count == 6)
    }

    @Test func sessionDriveLetterIsHonoredAndAnInvalidOneLeavesNoSnapshot() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let (store, _) = try await zzzStore(root)
        let prepared = try await prepareZZZ(store, root: root, letter: "N")
        let ini = try String(contentsOf: prepared.sessionDirectory.appendingPathComponent("payload/d3dx.ini"),
            encoding: .utf8)
        #expect(value(ini, "Include", "user_config")
            == ["N:\\\(prepared.sessionDirectory.lastPathComponent)\\payload\\d3dx_user.ini"])
        let before = Set(sessions(root))
        for letter in ["m", "MM", "", "Z", "C", "1"] {
            await #expect(throws: LauncherError.self) { _ = try await prepareZZZ(store, root: root, letter: letter) }
        }
        #expect(Set(sessions(root)) == before)
    }

    @Test func starRailSnapshotINIIsByteIdenticalToTheHookRunnerOutput() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let store = ModSupportStore(paths: appPaths(root), profile: .starRail)
        let package = try PackageFixture(root: root)
        try await store.install(manifest: package.manifest(), archive: package.archive)
        try await store.setInjectionEnabled(true, acknowledgingRisk: true)
        let backend = try makeBackend(root: root)
        // Exact pre-existing hook-runner output for this CRLF fixture. `D3DXIni`
        // does not split CRLF lines (Swift treats "\r\n" as one Character), so
        // it appends fresh sections; Star Rail keeps that behavior unchanged.
        let fixture = "; fixture\r\n[Loader]\r\ntarget = Other.exe\r\nloader = old.exe\r\n"
            + "module = d3d11.dll\r\n\r\n[System]\r\nproxy_d3d11 = Z:\\old\\d3d11.dll\r\n\r\n"
            + "[Include]\r\ninclude_recursive = Mods\r\n"
        let expected = fixture + "\r\n\r\n[Loader]\r\nloader = hook-runner.exe\r\ntarget = StarRail.exe\r\n"
            + "\r\n[System]\r\nproxy_d3d11 = Z:" + backend.path.replacingOccurrences(of: "/", with: "\\")
            + "\r\n\r\n[Include]\r\ninclude_recursive = Mods\r\n"
        for letter in ["M", "N"] {
            let prepared = try #require(try await store.prepareLaunch(gameID: "starrail",
                runtimeBundleID: fixtureRuntime, backendD3D11: backend, sessionDriveLetter: letter))
            #expect(prepared.loadingMode == .hookRunner)
            #expect(try Data(contentsOf: prepared.sessionDirectory.appendingPathComponent("payload/d3dx.ini"))
                == Data(expected.utf8))
            #expect(prepared.runnerURL.lastPathComponent == "hook-runner.exe")
        }
    }

    @Test(arguments: ["payload/d3dcompiler_47.dll", "payload/Core/ZZMI/main.ini", "payload/d3dx.ini"])
    func missingNativeFileFailsClosedWithoutASnapshot(_ missing: String) async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let (store, _) = try await zzzStore(root, overrides: nativeFiles(without: [missing]), removing: [missing])
        await #expect(throws: LauncherError.self) { _ = try await prepareZZZ(store, root: root) }
        await store.drainReclamation()
        #expect(sessions(root).isEmpty)
    }

    @Test(arguments: [
        nativeINI.replacingOccurrences(of: "include = Core\\ZZMI\\main.ini", with: "; include = Core\\ZZMI\\main.ini"),
        nativeINI.replacingOccurrences(of: "include = Core\\ZZMI\\main.ini", with: "include = Core\\Other\\main.ini"),
        nativeINI.replacingOccurrences(of: "include = Core\\ZZMI\\main.ini",
            with: "include = Core\\ZZMI\\main.ini\ninclude = Z:\\elsewhere\\main.ini"),
        nativeINI.replacingOccurrences(of: "include_recursive = Mods", with: ";include_recursive = Mods"),
        nativeINI.replacingOccurrences(of: "include_recursive = Mods",
            with: "include_recursive = Mods\ninclude_recursive = Z:\\Mods"),
        nativeINI.replacingOccurrences(of: "cache_directory = ShaderCache",
            with: "cache_directory = ShaderCache\ncache_directory = Other"),
    ])
    func missingOrConflictingIncludesFailClosed(_ ini: String) async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let (store, _) = try await zzzStore(root, overrides: nativeFiles(ini: ini))
        await #expect(throws: LauncherError.self) { _ = try await prepareZZZ(store, root: root) }
        await store.drainReclamation()
        #expect(sessions(root).isEmpty)
        // Only the snapshot copy is ever edited: the installed source is intact.
        let installed = appPaths(root).root.appendingPathComponent(
            "XXMI/Versions/zzz/\(fixtureVersion)/payload/d3dx.ini")
        #expect(try Data(contentsOf: installed) == Data(ini.utf8))
    }

    @Test func directX12StillBlocksBeforeAnySnapshot() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let (store, _) = try await zzzStore(root)
        await #expect(throws: LauncherError.self) { _ = try await prepareZZZ(store, root: root, directX12: true) }
        #expect(sessions(root).isEmpty)
    }

    @Test func nativeSnapshotKeepsUserSettingsHarvestAndLiveApplyPaths() async throws {
        let root = try makeTestRoot(); defer { removeTestRoot(root) }
        let (store, _) = try await zzzStore(root)
        let first = try await prepareZZZ(store, root: root)
        let settings = Data("$zzmi_toggle = 1\r\n".utf8)
        try writeFile(settings, to: first.sessionDirectory.appendingPathComponent("payload/d3dx_user.ini"))
        #expect(try await store.finishLaunch(sessionDirectory: first.sessionDirectory) == .stored)
        let second = try await prepareZZZ(store, root: root)
        #expect(try Data(contentsOf: second.sessionDirectory.appendingPathComponent("payload/d3dx_user.ini"))
            == settings)
        try await store.importMod(from: makeModFolder(root: root, name: "Live"))
        #expect(try await store.applyLiveMods(sessionDirectory: second.sessionDirectory).enabledMods == 1)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: second.sessionDirectory.appendingPathComponent("payload/Mods").path).count == 1)
    }
}
