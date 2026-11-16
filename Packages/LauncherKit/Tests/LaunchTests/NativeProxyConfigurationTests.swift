// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import GameLibrary
import RuntimeManager
import TestSupport
@testable import Launch

private let nativeBundleID = "d3dmetal-wine11.20-gptk4.0b3"

private func nativeRootDrive(_ f: ManagerFixture) throws {
    let dosdevices = f.prefix.appendingPathComponent("dosdevices", isDirectory: true)
    try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
    let link = dosdevices.appendingPathComponent("z:")
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil {
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/")
    }
}

private func nativeBundle(_ f: ManagerFixture) throws -> InstalledRuntimeBundle {
    let root = f.paths.runtimes.appendingPathComponent("bundles/verified", isDirectory: true)
    let windows = root.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
    try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
    try Data("d3d11".utf8).write(to: windows.appendingPathComponent("d3d11.dll"))
    return InstalledRuntimeBundle(id: try SafeIdentifier(nativeBundleID), root: root,
        wineBinary: root.appendingPathComponent("bin/wine"), digest: f.bundle.digest, source: .download)
}

/// A complete synthetic native session at `XXMI/Sessions/<game>/<UUID>`.
private func nativeSession(_ f: ManagerFixture, game: String = "zzz", name: String = UUID().uuidString,
    omit: Set<String> = [], loading: ModLoadingMode? = .nativeProxy, gameID: String? = "zzz",
    target: String? = "ZenlessZoneZero.exe") throws -> LaunchInjectionConfiguration {
    let session = f.paths.root.appendingPathComponent("XXMI/Sessions/\(game)/\(name)", isDirectory: true)
    let payload = session.appendingPathComponent("payload", isDirectory: true)
    for directory in ["Core/ZZMI", "Mods", "ShaderFixes"] where !omit.contains(directory) {
        try FileManager.default.createDirectory(at: payload.appendingPathComponent(directory),
            withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    for file in ["hook-runner.exe", "3dmloader.dll"] {
        try Data(file.utf8).write(to: session.appendingPathComponent(file))
    }
    for file in ["d3d11.dll", "d3dcompiler_47.dll", "d3dx.ini", "Core/ZZMI/main.ini"] where !omit.contains(file) {
        try Data(file.utf8).write(to: payload.appendingPathComponent(file))
    }
    return LaunchInjectionConfiguration(runnerURL: session.appendingPathComponent("hook-runner.exe"),
        injectorURL: session.appendingPathComponent("3dmloader.dll"),
        payloadURL: payload.appendingPathComponent("d3d11.dll"), sessionDirectory: session,
        gameID: gameID, targetExecutable: target, loading: loading)
}

private func resolved(_ f: ManagerFixture, game: String, bundle: InstalledRuntimeBundle) throws
    -> (ResolvedLaunch, String) {
    let recipe = try #require(Recipes.recipe(for: game))
    try Data("game".utf8).write(to: recipe.executable.resolved(against: f.installRoot))
    let launch = try LaunchResolver.resolve(recipe: recipe, settings: .defaults(for: game),
        installRoot: f.installRoot, prefix: f.prefix, wineBinary: bundle.wineBinary, proxyPort: 4321,
        componentRoots: f.runtime.selected.componentRoots.merging([.steamShim: URL(fileURLWithPath: "/shim")]) { a, _ in a },
        baseEnvironment: [:],
        runtimeBundleID: bundle.id.rawValue)
    return (launch, WinePath.windowsPath(for: recipe.executable.resolved(against: f.installRoot)))
}

private func decode(_ json: String) throws -> LaunchInjectionConfiguration {
    try JSONDecoder().decode(LaunchInjectionConfiguration.self, from: Data(json.utf8))
}

@Suite(.timeLimit(.minutes(1))) struct NativeProxyConfigurationTests {
    @Test func sessionDriveConstantKeepsTheExistingHSRDrive() {
        #expect(LaunchInjectionConfiguration.sessionDriveLetter == "M")
        #expect(LaunchInjection.sessionDrive == "m:")
    }

    @Test func legacyRecordsDecodeAsHookRunnerAndEncodeWithoutTheNewKey() throws {
        let old = try decode("""
            {"runnerURL":"file:///s/hook-runner.exe","injectorURL":"file:///s/3dmloader.dll",
             "payloadURL":"file:///s/payload/d3d11.dll","sessionDirectory":"file:///s/"}
            """)
        #expect(old.loading == nil)
        #expect(old.resolvedLoading == .hookRunner)
        try old.validateForJournal()
        let encoded = try #require(String(data: JSONEncoder().encode(old), encoding: .utf8))
        #expect(!encoded.contains("loading"))
        // A ZZZ hook-runner record written before native loading still validates
        // during recovery; mode gating belongs to fresh preparation only.
        let zzz = try decode("""
            {"runnerURL":"file:///s/hook-runner.exe","injectorURL":"file:///s/3dmloader.dll",
             "payloadURL":"file:///s/payload/d3d11.dll","sessionDirectory":"file:///s/",
             "gameID":"zzz","targetExecutable":"ZenlessZoneZero.exe"}
            """)
        #expect(zzz.resolvedLoading == .hookRunner)
        try zzz.validateForJournal()
    }

    @Test func nativeRecordsRoundTripAndRequireTheZZZIdentity() throws {
        let native = LaunchInjectionConfiguration(runnerURL: URL(fileURLWithPath: "/s/hook-runner.exe"),
            injectorURL: URL(fileURLWithPath: "/s/3dmloader.dll"),
            payloadURL: URL(fileURLWithPath: "/s/payload/d3d11.dll"),
            sessionDirectory: URL(fileURLWithPath: "/s", isDirectory: true), gameID: "zzz",
            targetExecutable: "ZenlessZoneZero.exe", loading: .nativeProxy)
        let data = try JSONEncoder().encode(native)
        #expect(String(data: data, encoding: .utf8)?.contains("\"loading\":\"nativeProxy\"") == true)
        #expect(try JSONDecoder().decode(LaunchInjectionConfiguration.self, from: data) == native)
        try native.validateForJournal()
        for (game, target) in [(nil, "ZenlessZoneZero.exe"), ("starrail", "ZenlessZoneZero.exe"),
            ("zzz", nil), ("zzz", "StarRail.exe")] as [(String?, String?)] {
            let wrong = LaunchInjectionConfiguration(runnerURL: native.runnerURL, injectorURL: native.injectorURL,
                payloadURL: native.payloadURL, sessionDirectory: native.sessionDirectory, gameID: game,
                targetExecutable: target, loading: .nativeProxy)
            #expect(throws: LauncherError.self) { try wrong.validateForJournal() }
        }
        #expect(throws: (any Error).self) {
            try decode("""
                {"runnerURL":"file:///s/a","injectorURL":"file:///s/b","payloadURL":"file:///s/c",
                 "sessionDirectory":"file:///s/","loading":"somethingElse"}
                """)
        }
    }

    @Test func nativeSnapshotValidatesKeepsTheSessionDriveAndSpawnsTheUnchangedCommand() async throws {
        let f = try await ManagerFixture.make()
        try nativeRootDrive(f)
        let bundle = try nativeBundle(f)
        let configuration = try nativeSession(f)
        let game = try #require(GameDefinition.find("zzz"))
        let prepared = try LaunchInjection.validate(configuration, paths: f.paths, prefix: f.prefix,
            bundle: bundle, game: game)
        #expect(prepared.loading == .nativeProxy)
        #expect(prepared.configuration.loading == .nativeProxy)
        let link = f.prefix.appendingPathComponent("dosdevices/m:")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == configuration.sessionDirectory.deletingLastPathComponent().standardizedFileURL.path)

        let (launch, gamePath) = try resolved(f, game: "zzz", bundle: bundle)
        #expect(try prepared.nativeLaunch(launch, expectedGamePath: gamePath) == launch)
        #expect(!launch.arguments.contains { $0.contains("hook-runner") })
        #expect(launch.arguments.contains(gamePath))
        // Never silently routes a native snapshot through the helper.
        #expect(throws: LauncherError.self) { try prepared.wrap(launch, expectedGamePath: gamePath) }
        // The expected-target guard still applies to the native path.
        #expect(throws: LauncherError.self) {
            try prepared.nativeLaunch(launch, expectedGamePath: "Z:\\other\\Game.exe")
        }
    }

    @Test func hookRunnerArgumentsAreUnchangedAndRefuseTheNativePath() async throws {
        let f = try await ManagerFixture.make()
        try nativeRootDrive(f)
        let bundle = try nativeBundle(f)
        let name = UUID().uuidString
        let session = f.paths.root.appendingPathComponent("XXMI/Sessions/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        for file in ["hook-runner.exe", "3dmloader.dll", "d3d11.dll"] {
            try Data(file.utf8).write(to: session.appendingPathComponent(file))
        }
        let configuration = LaunchInjectionConfiguration(runnerURL: session.appendingPathComponent("hook-runner.exe"),
            injectorURL: session.appendingPathComponent("3dmloader.dll"),
            payloadURL: session.appendingPathComponent("d3d11.dll"), sessionDirectory: session)
        let prepared = try LaunchInjection.validate(configuration, paths: f.paths, prefix: f.prefix,
            bundle: bundle, game: try #require(GameDefinition.find("starrail")))
        #expect(prepared.loading == .hookRunner)
        let (launch, gamePath) = try resolved(f, game: "starrail", bundle: bundle)
        let wrapped = try prepared.wrap(launch, expectedGamePath: gamePath)
        #expect(wrapped.arguments == ["M:\\\(name)\\hook-runner.exe", "--loader", "M:\\\(name)\\3dmloader.dll",
            "--payload", "M:\\\(name)\\d3d11.dll", "--"] + launch.arguments)
        #expect(wrapped.executable == launch.executable && wrapped.environment == launch.environment)
        #expect(throws: LauncherError.self) { try prepared.nativeLaunch(launch, expectedGamePath: gamePath) }
    }

    @Test(arguments: ["d3dcompiler_47.dll", "d3dx.ini", "Core/ZZMI/main.ini", "Mods"])
    func nativeSnapshotMissingARequiredItemFailsClosed(_ missing: String) async throws {
        let f = try await ManagerFixture.make()
        try nativeRootDrive(f)
        let bundle = try nativeBundle(f)
        let configuration = try nativeSession(f, omit: [missing])
        #expect(throws: LauncherError.self) {
            try LaunchInjection.validate(configuration, paths: f.paths, prefix: f.prefix, bundle: bundle,
                game: try #require(GameDefinition.find("zzz")))
        }
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: f.prefix.appendingPathComponent("dosdevices/m:").path)) == nil)
    }

    @Test func nativeSnapshotRefusesSymlinksAndForeignSessions() async throws {
        let f = try await ManagerFixture.make()
        try nativeRootDrive(f)
        let bundle = try nativeBundle(f)
        let game = try #require(GameDefinition.find("zzz"))
        // Mods replaced by a symlink to a directory outside the snapshot.
        let linked = try nativeSession(f, omit: ["Mods"])
        let outside = f.temp.url.appendingPathComponent("outside-mods", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.payloadURL.deletingLastPathComponent()
            .appendingPathComponent("Mods"), withDestinationURL: outside)
        // A d3dcompiler symlink, even to a real file, is not a snapshot file.
        let linkedFile = try nativeSession(f, omit: ["d3dcompiler_47.dll"])
        try FileManager.default.createSymbolicLink(at: linkedFile.payloadURL.deletingLastPathComponent()
            .appendingPathComponent("d3dcompiler_47.dll"), withDestinationURL: linkedFile.payloadURL)
        // Star Rail's sessions folder and non-canonical names are foreign to ZZZ.
        let foreign = try nativeSession(f, game: "starrail-like")
        let unnamed = try nativeSession(f, name: "not-a-uuid")
        for configuration in [linked, linkedFile, foreign, unnamed] {
            #expect(throws: LauncherError.self) {
                try LaunchInjection.validate(configuration, paths: f.paths, prefix: f.prefix, bundle: bundle,
                    game: game)
            }
        }
        // A native record for the other game never validates for ZZZ either.
        #expect(throws: LauncherError.self) {
            try LaunchInjection.validate(try nativeSession(f, gameID: "starrail", target: "StarRail.exe"),
                paths: f.paths, prefix: f.prefix, bundle: bundle, game: game)
        }
    }
}
