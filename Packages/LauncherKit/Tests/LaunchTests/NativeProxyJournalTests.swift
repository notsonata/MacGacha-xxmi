// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import TestSupport
@testable import Launch

/// A real placed record for one session, plus a matching journal context.
private struct JournalFixture {
    let temp: ManagerTemporaryDirectory
    let paths: AppPaths
    let installRoot: URL
    let prefix: URL
    let configuration: LaunchInjectionConfiguration
    let sessionID = UUID()
    let record: NativeProxyRecord

    init() throws {
        temp = try ManagerTemporaryDirectory()
        paths = AppPaths(root: temp.url.appendingPathComponent("store"))
        installRoot = temp.url.appendingPathComponent("game")
        prefix = paths.prefixes.appendingPathComponent("zzz-d3dmetal")
        let fm = FileManager.default
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        for name in ["d3d11.dll", "d3dcompiler_47.dll"] { try Data("builtin \(name)".utf8).write(to: system32.appendingPathComponent(name)) }
        let session = paths.root.appendingPathComponent("XXMI/Sessions/zzz/\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        let payload = session.appendingPathComponent("payload")
        for directory in ["Core/ZZMI", "Mods"] { try fm.createDirectory(at: payload.appendingPathComponent(directory), withIntermediateDirectories: true) }
        for name in ["d3d11.dll", "d3dcompiler_47.dll", "d3dx.ini", "Core/ZZMI/main.ini"] { try Data(name.utf8).write(to: payload.appendingPathComponent(name)) }
        configuration = LaunchInjectionConfiguration(runnerURL: session.appendingPathComponent("hook-runner.exe"),
            injectorURL: session.appendingPathComponent("3dmloader.dll"), payloadURL: payload.appendingPathComponent("d3d11.dll"),
            sessionDirectory: session, gameID: "zzz", targetExecutable: "ZenlessZoneZero.exe", loading: .nativeProxy)
        var placed: NativeProxyRecord?
        try NativeProxyFiles().place(sessionDirectory: session, prefix: prefix.standardizedFileURL, sessionID: sessionID,
            record: &placed) { _ in }
        record = try #require(placed)
    }

    func session(id: UUID? = nil, game: String = "zzz", prefix: URL? = nil, injection: LaunchInjectionConfiguration?? = nil,
        nativeProxy: NativeProxyRecord?? = nil, state: LaunchSession.State = .running) throws -> LaunchSession {
        LaunchSession(sessionID: id ?? sessionID, game: game, installRoot: installRoot,
            installIdentity: try ContainedFileSystem(root: installRoot).rootIdentity(), prefix: prefix ?? self.prefix,
            bundleID: "bundle-a", runtimeDigest: testDigest(Data()), wineBinary: URL(fileURLWithPath: "/wine/bin/wine"),
            wineserver: URL(fileURLWithPath: "/wine/bin/wineserver"), componentIDs: ["wine-a"], recipeVersion: 1,
            settings: LaunchSettings(backend: .d3dmetal, retina: false, frameLimit: nil, directX12: false, compatibilityPatches: false),
            state: state, injection: injection ?? configuration, nativeProxy: nativeProxy ?? record)
    }
}

@Suite(.timeLimit(.minutes(1))) struct NativeProxyJournalTests {
    @Test func legacyJournalsDecodeWithoutNativeOwnershipAndKeepTheirBytes() throws {
        let f = try JournalFixture()
        // Mods OFF and legacy ZZZ hook-runner journals remain valid and never encode the key.
        let legacyHook = LaunchInjectionConfiguration(runnerURL: f.configuration.runnerURL, injectorURL: f.configuration.injectorURL,
            payloadURL: f.configuration.payloadURL, sessionDirectory: f.configuration.sessionDirectory,
            gameID: "zzz", targetExecutable: "ZenlessZoneZero.exe")
        let journal = LaunchJournal(paths: f.paths)
        for injection in [nil, legacyHook] as [LaunchInjectionConfiguration?] {
            let session = try f.session(injection: .some(injection), nativeProxy: .some(nil))
            let data = try journal.encode(session)
            #expect(!String(decoding: data, as: UTF8.self).contains("nativeProxy"))
            try journal.write(session)
            let read = try #require(try journal.read(game: "zzz"))
            #expect(read.nativeProxy == nil)
            #expect(read == session)
            try journal.write({ var done = read; done.state = .done; return done }())
            try journal.delete(game: "zzz")
        }
    }

    @Test func nativeOwnershipRoundTripsAndBlocksDeletionUntilCleared() throws {
        let f = try JournalFixture()
        let journal = LaunchJournal(paths: f.paths)
        var session = try f.session(state: .done)
        try journal.write(session)
        #expect(try journal.read(game: "zzz")?.nativeProxy == f.record)
        #expect(throws: LauncherError.self) { try journal.delete(game: "zzz") }
        session.state = .recoveryConflict
        try journal.write(session)
        #expect(throws: LauncherError.self) { try journal.delete(game: "zzz") }
        #expect(try journal.read(game: "zzz") != nil)
        session.nativeProxy = nil
        session.state = .done
        try journal.write(session)
        try journal.delete(game: "zzz")
        #expect(try journal.read(game: "zzz") == nil)
    }

    enum Malformed: CaseIterable { case otherSession, otherPrefix, noInjection, hookInjection, otherGame, otherSnapshot }

    @Test(arguments: Malformed.allCases) func crossRecordMismatchIsRejectedOnWriteAndRead(_ kind: Malformed) throws {
        let f = try JournalFixture()
        let otherSnapshot = LaunchInjectionConfiguration(runnerURL: f.configuration.runnerURL, injectorURL: f.configuration.injectorURL,
            payloadURL: f.configuration.payloadURL,
            sessionDirectory: f.paths.root.appendingPathComponent("XXMI/Sessions/zzz/\(UUID().uuidString)"),
            gameID: "zzz", targetExecutable: "ZenlessZoneZero.exe", loading: .nativeProxy)
        let hook = LaunchInjectionConfiguration(runnerURL: f.configuration.runnerURL, injectorURL: f.configuration.injectorURL,
            payloadURL: f.configuration.payloadURL, sessionDirectory: f.configuration.sessionDirectory,
            gameID: "zzz", targetExecutable: "ZenlessZoneZero.exe")
        let bad: LaunchSession = switch kind {
        case .otherSession: try f.session(id: UUID())
        case .otherPrefix: try f.session(prefix: f.paths.prefixes.appendingPathComponent("zzz-other"))
        case .noInjection: try f.session(injection: .some(nil))
        case .hookInjection: try f.session(injection: hook)
        case .otherGame: try f.session(game: "starrail", injection: .some(nil))
        case .otherSnapshot: try f.session(injection: otherSnapshot)
        }
        let journal = LaunchJournal(paths: f.paths)
        #expect(throws: LauncherError.self) { try journal.write(bad) }
        #expect(try journal.read(game: bad.game) == nil)
        // A hand-edited journal with the same mismatch is corrupt, never trusted.
        let path = f.paths.root.appendingPathComponent("Games/\(bad.game)/launch-session.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try journal.encode(bad).write(to: path)
        #expect(throws: LauncherError.self) { _ = try journal.read(game: bad.game) }
    }
}
