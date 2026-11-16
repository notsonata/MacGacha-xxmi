// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import Launch

private let builtinD3D11 = Data("wine builtin d3d11 placeholder".utf8)
private let builtinCompiler = Data("wine builtin d3dcompiler_47 placeholder".utf8)
private let proxyD3D11 = Data("native proxy d3d11 bytes".utf8)
private let proxyCompiler = Data("native d3dcompiler_47 bytes".utf8)
private let nativeINI = Data("[Loader]\nuser_config=M:\\s\\d3dx_user.ini\n".utf8)

private struct SimulatedCrash: Error {}

/// A JSON round-trip journal: only successful writes become durable.
private final class NativeProxyJournal {
    var durable: NativeProxyRecord?
    var writes = 0
    var failAtWrite: Int?
    func persist(_ record: NativeProxyRecord?) throws {
        defer { writes += 1 }
        if failAtWrite == writes { throw LauncherError.io("Injected journal failure") }
        durable = try record.map { try JSONDecoder().decode(NativeProxyRecord.self, from: JSONEncoder().encode($0)) }
    }
}

private final class NativeProxyFixture {
    let temp: FixtureDirectory
    let root: URL
    let prefix: URL
    let system32: URL
    let session: URL
    let sessionID = UUID()
    let journal = NativeProxyJournal()
    var record: NativeProxyRecord?

    init(compilerOriginal: Bool = true) throws {
        temp = try FixtureDirectory()
        root = temp.url.resolvingSymlinksInPath()
        prefix = root.appendingPathComponent("prefixes/zzz")
        system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        session = root.appendingPathComponent("XXMI/Sessions/\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try builtinD3D11.write(to: system32.appendingPathComponent("d3d11.dll"))
        if compilerOriginal { try builtinCompiler.write(to: system32.appendingPathComponent("d3dcompiler_47.dll")) }
        try Data("unrelated".utf8).write(to: system32.appendingPathComponent("kernel32.dll"))
        let payload = session.appendingPathComponent("payload")
        try fm.createDirectory(at: payload.appendingPathComponent("Core/ZZMI"), withIntermediateDirectories: true)
        try fm.createDirectory(at: payload.appendingPathComponent("Mods/Example"), withIntermediateDirectories: true)
        try Data("core".utf8).write(to: payload.appendingPathComponent("Core/ZZMI/main.ini"))
        try proxyD3D11.write(to: payload.appendingPathComponent("d3d11.dll"))
        try proxyCompiler.write(to: payload.appendingPathComponent("d3dcompiler_47.dll"))
        try nativeINI.write(to: payload.appendingPathComponent("d3dx.ini"))
    }

    func url(_ name: String) -> URL { system32.appendingPathComponent(name) }

    func place(_ files: NativeProxyFiles = NativeProxyFiles()) throws {
        try files.place(sessionDirectory: session, prefix: prefix, sessionID: sessionID, record: &record, persist: journal.persist)
    }

    func restore(_ files: NativeProxyFiles = NativeProxyFiles()) -> NativeProxyRestoreOutcome {
        files.restore(prefix: prefix, sessionID: sessionID, record: &record, persist: journal.persist)
    }

    /// Names, kinds, bytes, link targets and inodes; never follows links.
    func snapshot() throws -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ url: URL, _ prefix: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                let child = url.appendingPathComponent(name), key = prefix + name
                var info = stat()
                guard lstat(child.path, &info) == 0 else { throw LauncherError.io("lstat") }
                switch info.st_mode & S_IFMT {
                case S_IFLNK: result[key] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: child.path))
                case S_IFDIR: result[key] = "dir"; try walk(child, key + "/")
                default: result[key] = "file:\(info.st_ino):\(info.st_nlink):" + (try Data(contentsOf: child)).base64EncodedString()
                }
            }
        }
        try walk(system32, "")
        return result
    }
}

private func crashHook(at step: NativeProxyFileStep, occurrence: Int = 1) -> @Sendable (NativeProxyFileStep) throws -> Void {
    let seen = Mutex(0)
    return { reached in
        guard reached == step else { return }
        let count = seen.withLock { $0 += 1; return $0 }
        if count == occurrence { throw SimulatedCrash() }
    }
}

/// Fails the first unlink of a named entry; models a transient restore failure.
private final class NativeProxyUnlinkFailure: FileOps, Sendable {
    private let name: String
    private let failed = Mutex(false)
    private let base = SystemFileOps()
    init(name: String) { self.name = name }
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
    }
    func unlink(_ entry: String, in dir: Int32, isDirectory: Bool) throws {
        if entry == name, !failed.withLock({ let was = $0; $0 = true; return was }) { throw LauncherError.io("Injected unlink failure") }
        try base.unlink(entry, in: dir, isDirectory: isDirectory)
    }
}

@Suite(.timeLimit(.minutes(1))) struct NativeProxyFilesTests {
    @Test func terminalFlagsStillRequireExactDiskRestoration() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        var record = try #require(f.record)
        record.phase = .restoring
        for i in record.originals.indices { record.originals[i].state = .restored }
        for i in record.files.indices { record.files[i].state = .removed }
        for i in record.links.indices { record.links[i].state = .removed }
        f.record = record
        try f.journal.persist(record)
        #expect(f.restore() == .clean)
        #expect(f.record == nil && f.journal.durable == nil)
        #expect(try f.snapshot() == baseline)
    }
    @Test func placesVerifiedFilesAndRestoresExactBaseline() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        let record = try #require(f.record)
        #expect(record.phase == .placed)
        #expect(f.journal.durable == record)
        #expect(try Data(contentsOf: f.url("d3d11.dll")) == proxyD3D11)
        #expect(try Data(contentsOf: f.url("d3dcompiler_47.dll")) == proxyCompiler)
        #expect(try Data(contentsOf: f.url("d3dx.ini")) == nativeINI)
        let hidden = NativeProxyRecord.hiddenName("d3d11.dll", sessionID: f.sessionID)
        #expect(try Data(contentsOf: f.url(hidden)) == builtinD3D11)
        for name in ["Core", "Mods"] {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.url(name).path)
                == f.session.path + "/payload/" + name)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.url("Mods").path) == ["Example"])

        // Runtime logs absent at placement are owned prospective outputs.
        try Data("log".utf8).write(to: f.url("d3d11_log.txt"))
        try Data("usage".utf8).write(to: f.url("ShaderUsage.txt"))
        #expect(f.restore() == .clean)
        #expect(f.record == nil && f.journal.durable == nil)
        #expect(try f.snapshot() == baseline) // Includes original inodes and bytes.

        // Idempotent: nothing owned, and a stale pre-clear record changes nothing.
        #expect(f.restore() == .clean)
        f.record = record
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    @Test(arguments: NativeProxyRecord.dllNames) func missingOriginalFailsPreflightWithoutChanges(name: String) throws {
        let f = try NativeProxyFixture()
        try FileManager.default.removeItem(at: f.url(name))
        let baseline = try f.snapshot()
        #expect(throws: NativeProxyError.self) { try f.place() }
        #expect(f.record == nil && f.journal.durable == nil && f.journal.writes == 0)
        #expect(try f.snapshot() == baseline)
    }

    enum Conflict: String, CaseIterable {
        case foreignINI, foreignCoreDirectory, foreignModsLink, caseFoldedMods, hardLinkedDLL, symlinkedDLL
        case directoryDLL, orphanHidden, orphanStage, orphanRemoval, existingLog, differentlyCasedDLL
        case symlinkedSystem32, symlinkedWindows, missingPayloadCore, payloadModsLink, missingPayloadINI
        case hardLinkedPayloadDLL, hardLinkedPayloadINI
    }

    @Test(arguments: Conflict.allCases) func preflightRefusesWithZeroChanges(_ conflict: Conflict) throws {
        let f = try NativeProxyFixture()
        let fm = FileManager.default
        let other = f.root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        switch conflict {
        case .foreignINI: try Data("user".utf8).write(to: f.url("d3dx.ini"))
        case .foreignCoreDirectory: try fm.createDirectory(at: f.url("Core"), withIntermediateDirectories: false)
        case .foreignModsLink: try fm.createSymbolicLink(at: f.url("Mods"), withDestinationURL: other)
        case .caseFoldedMods: try fm.createDirectory(at: f.url("mods"), withIntermediateDirectories: false)
        case .hardLinkedDLL: try fm.linkItem(at: f.url("d3d11.dll"), to: other.appendingPathComponent("copy.dll"))
        case .symlinkedDLL:
            try fm.removeItem(at: f.url("d3dcompiler_47.dll"))
            try builtinCompiler.write(to: other.appendingPathComponent("c.dll"))
            try fm.createSymbolicLink(at: f.url("d3dcompiler_47.dll"), withDestinationURL: other.appendingPathComponent("c.dll"))
        case .directoryDLL:
            try fm.removeItem(at: f.url("d3dcompiler_47.dll"))
            try fm.createDirectory(at: f.url("d3dcompiler_47.dll"), withIntermediateDirectories: false)
        case .orphanHidden: try Data().write(to: f.url("d3d11.dll.macgacha-hidden-" + UUID().uuidString))
        case .orphanStage: try Data().write(to: f.url(".macgacha-native-\(UUID().uuidString)-d3dx.ini"))
        case .orphanRemoval: try fm.createDirectory(at: f.url(".macgacha-remove-\(UUID().uuidString)"), withIntermediateDirectories: false)
        case .existingLog: try Data("old".utf8).write(to: f.url("d3d11_log.txt"))
        case .differentlyCasedDLL:
            // On a case-sensitive volume this is a second entry; on APFS default
            // it renames the only one. Either way the exact name is not alone.
            try fm.moveItem(at: f.url("d3d11.dll"), to: f.url("D3D11.dll"))
        case .symlinkedSystem32:
            let windows = f.prefix.appendingPathComponent("drive_c/windows")
            try fm.moveItem(at: f.system32, to: other.appendingPathComponent("system32"))
            try fm.createSymbolicLink(at: windows.appendingPathComponent("system32"), withDestinationURL: other.appendingPathComponent("system32"))
        case .symlinkedWindows:
            let driveC = f.prefix.appendingPathComponent("drive_c")
            try fm.moveItem(at: driveC.appendingPathComponent("windows"), to: other.appendingPathComponent("windows"))
            try fm.createSymbolicLink(at: driveC.appendingPathComponent("windows"), withDestinationURL: other.appendingPathComponent("windows"))
        case .missingPayloadCore: try fm.removeItem(at: f.session.appendingPathComponent("payload/Core"))
        case .payloadModsLink:
            let mods = f.session.appendingPathComponent("payload/Mods")
            try fm.moveItem(at: mods, to: other.appendingPathComponent("Mods"))
            try fm.createSymbolicLink(at: mods, withDestinationURL: other.appendingPathComponent("Mods"))
        case .missingPayloadINI: try fm.removeItem(at: f.session.appendingPathComponent("payload/d3dx.ini"))
        case .hardLinkedPayloadDLL:
            try fm.linkItem(at: f.session.appendingPathComponent("payload/d3d11.dll"), to: other.appendingPathComponent("alias.dll"))
        case .hardLinkedPayloadINI:
            try fm.linkItem(at: f.session.appendingPathComponent("payload/d3dx.ini"), to: other.appendingPathComponent("alias.ini"))
        }
        let symlinkedRoot = conflict == .symlinkedSystem32 || conflict == .symlinkedWindows
        let before = symlinkedRoot ? [:] : try f.snapshot()
        let elsewhere = try fm.subpathsOfDirectory(atPath: other.path).sorted()
        #expect(throws: NativeProxyError.self) { try f.place() }
        #expect(f.record == nil)
        #expect(f.journal.writes == 0)
        if !symlinkedRoot { #expect(try f.snapshot() == before) }
        #expect(try fm.subpathsOfDirectory(atPath: other.path).sorted() == elsewhere)
    }

    @Test func existingRecordIsBusy() throws {
        let f = try NativeProxyFixture()
        try f.place()
        let placed = try f.snapshot()
        #expect(throws: NativeProxyError.busy) { try f.place() }
        #expect(try f.snapshot() == placed)
        #expect(f.restore() == .clean)
    }

    @Test func substitutedPlacedFileRetainsOriginalAndForeignFile() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        let foreign = Data("updated by something else".utf8)
        try FileManager.default.removeItem(at: f.url("d3d11.dll"))
        try foreign.write(to: f.url("d3d11.dll"))
        let hidden = NativeProxyRecord.hiddenName("d3d11.dll", sessionID: f.sessionID)
        guard case .conflict(let retained) = f.restore() else { Issue.record("Expected conflict"); return }
        #expect(Set(retained) == ["d3d11.dll", hidden])
        #expect(f.record != nil && f.journal.durable == f.record)
        #expect(try Data(contentsOf: f.url("d3d11.dll")) == foreign)
        #expect(try Data(contentsOf: f.url(hidden)) == builtinD3D11)
        #expect(try Data(contentsOf: f.url("d3dcompiler_47.dll")) == builtinCompiler)
        #expect(!FileManager.default.fileExists(atPath: f.url("Core").path))
        // Repeating is stable; once the user removes the foreign file it completes.
        guard case .conflict = f.restore() else { Issue.record("Expected conflict"); return }
        try FileManager.default.removeItem(at: f.url("d3d11.dll"))
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    @Test func modifiedPlacedInodeIsStillOurs() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        let handle = try FileHandle(forWritingTo: f.url("d3dx.ini"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("x".utf8)); try handle.close()
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    @Test func substitutedLinkDirectoryIsNeverRemoved() throws {
        let f = try NativeProxyFixture()
        try f.place()
        try FileManager.default.removeItem(at: f.url("Core"))
        try FileManager.default.createDirectory(at: f.url("Core"), withIntermediateDirectories: false)
        try Data("user".utf8).write(to: f.url("Core/user.ini"))
        // A link with a different target is likewise foreign.
        try FileManager.default.removeItem(at: f.url("Mods"))
        try FileManager.default.createSymbolicLink(atPath: f.url("Mods").path, withDestinationPath: f.session.path + "/payload/Mods/")
        guard case .conflict(let retained) = f.restore() else { Issue.record("Expected conflict"); return }
        #expect(Set(retained) == ["Core", "Mods"])
        #expect(try Data(contentsOf: f.url("Core/user.ini")) == Data("user".utf8))
        #expect(try Data(contentsOf: f.url("d3d11.dll")) == builtinD3D11)
        #expect(f.record?.files.allSatisfy { $0.state == .removed } == true)
        #expect(f.record?.originals.allSatisfy { $0.state == .restored } == true)
    }

    @Test func changedHiddenOriginalIsRetained() throws {
        let f = try NativeProxyFixture()
        try f.place()
        let hidden = f.url(NativeProxyRecord.hiddenName("d3dcompiler_47.dll", sessionID: f.sessionID))
        try Data("tampered".utf8).write(to: hidden)
        guard case .conflict(let retained) = f.restore() else { Issue.record("Expected conflict"); return }
        #expect(retained == [hidden.lastPathComponent])
        #expect(try Data(contentsOf: hidden) == Data("tampered".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.url("d3dcompiler_47.dll").path))
        #expect(try Data(contentsOf: f.url("d3d11.dll")) == builtinD3D11)
        #expect(f.record != nil)
    }

    @Test func foreignProspectiveOutputIsRetained() throws {
        let f = try NativeProxyFixture()
        try f.place()
        try FileManager.default.createDirectory(at: f.url("ShaderUsage.txt"), withIntermediateDirectories: false)
        #expect(f.restore() == .conflict(retained: ["ShaderUsage.txt"]))
        #expect(FileManager.default.fileExists(atPath: f.url("ShaderUsage.txt").path))
        #expect(f.record != nil)
    }

    @Test func deletedSnapshotLeavesDanglingLinksThatAreRemoved() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        try FileManager.default.removeItem(at: f.session)
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    @Test func substitutedSystem32IsRefused() throws {
        let f = try NativeProxyFixture()
        try f.place()
        let moved = f.system32.deletingLastPathComponent().appendingPathComponent("system32.moved")
        try FileManager.default.moveItem(at: f.system32, to: moved)
        try FileManager.default.createDirectory(at: f.system32, withIntermediateDirectories: false)
        let movedBefore = try FileManager.default.contentsOfDirectory(atPath: moved.path).sorted()
        #expect(f.restore() == .conflict(retained: ["system32"]))
        #expect(f.record != nil && f.journal.durable?.phase == .placed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.system32.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).sorted() == movedBefore)
    }

    enum Tamper: String, CaseIterable {
        case linkTarget, hiddenName, stageName, sourcePath, sessionID, prefix, extraFile, version
        // Original entries must be exactly the accepted two-DLL baseline.
        case noOriginals, oneOriginal, duplicateOriginal, reorderedOriginals, originalIdentity
        case restoredOriginalWithPlacedFile, plannedOriginalWithPlacedFile, fileIdentityIsOriginal
        case missingRemovalArea
    }

    @Test(arguments: Tamper.allCases) func tamperedRecordIsRejectedBeforeDiskAccess(_ tamper: Tamper) throws {
        let f = try NativeProxyFixture()
        try f.place()
        let placed = try f.snapshot()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.record)) as? [String: Any])
        func edit(_ key: String, _ index: Int, _ field: String, _ value: Any) {
            var list = json[key] as! [[String: Any]]; list[index][field] = value; json[key] = list
        }
        switch tamper {
        case .linkTarget: edit("links", 0, "target", f.root.path)
        case .hiddenName: edit("originals", 0, "hiddenName", "kernel32.dll")
        case .stageName: edit("files", 2, "stageName", "kernel32.dll")
        case .sourcePath: edit("files", 0, "sourcePath", "payload/d3dx.ini")
        case .sessionID: json["sessionID"] = UUID().uuidString
        case .prefix: json["prefix"] = f.root.appendingPathComponent("elsewhere").absoluteString
        case .extraFile:
            var list = json["files"] as! [[String: Any]]
            var extra = list[2]; extra["name"] = "kernel32.dll"; list.append(extra); json["files"] = list
        case .version: json["version"] = 2
        case .noOriginals: json["originals"] = [[String: Any]]()
        case .oneOriginal: json["originals"] = [(json["originals"] as! [[String: Any]])[0]]
        case .duplicateOriginal:
            let list = json["originals"] as! [[String: Any]]; json["originals"] = [list[0], list[0]]
        case .reorderedOriginals:
            let list = json["originals"] as! [[String: Any]]; json["originals"] = [list[1], list[0]]
        case .originalIdentity:
            var list = json["originals"] as! [[String: Any]]
            var print = list[0]["original"] as! [String: Any], identity = print["identity"] as! [String: Any]
            identity["inode"] = (identity["inode"] as! NSNumber).uint64Value + 1
            print["identity"] = identity; list[0]["original"] = print; json["originals"] = list
        case .restoredOriginalWithPlacedFile: json["phase"] = "restoring"; edit("originals", 0, "state", "restored")
        case .plannedOriginalWithPlacedFile: json["phase"] = "restoring"; edit("originals", 0, "state", "planned")
        case .fileIdentityIsOriginal:
            let list = json["originals"] as! [[String: Any]]
            edit("files", 2, "identity", (list[0]["original"] as! [String: Any])["identity"]!)
        case .missingRemovalArea: json.removeValue(forKey: "removalArea")
        }
        f.record = try JSONDecoder().decode(NativeProxyRecord.self, from: JSONSerialization.data(withJSONObject: json))
        let writes = f.journal.writes
        guard case .pending = f.restore() else { Issue.record("Expected pending"); return }
        #expect(f.record != nil && f.journal.writes == writes)
        #expect(try f.snapshot() == placed)
    }

    // MARK: Crash boundaries

    @Test(arguments: NativeProxyFileStep.placeSteps, [1, 2, 3])
    func crashDuringPlacementRecoversFromDurableRecord(_ step: NativeProxyFileStep, occurrence: Int) throws {
        for useDurable in [true, false] {
            let f = try NativeProxyFixture()
            let baseline = try f.snapshot()
            var crashed = false
            do { try f.place(NativeProxyFiles(hook: crashHook(at: step, occurrence: occurrence))) }
            catch is SimulatedCrash { crashed = true }
            // Process death: recover from what was durable, or from the newest in-memory value.
            if useDurable { f.record = f.journal.durable }
            #expect(f.record != nil)
            // Death after creating an artifact but before its identity is durable
            // leaves something only a reserved name connects to us: retain it.
            let unrecorded: String? = switch (crashed && useDurable, step) {
            case (true, .afterAreaCreate): NativeProxyRecord.removalAreaName(sessionID: f.sessionID)
            case (true, .afterStageCreate): NativeProxyRecord.stageName(NativeProxyRecord.fileNames[occurrence - 1], sessionID: f.sessionID)
            default: nil
            }
            if let unrecorded {
                let before = try f.snapshot()
                guard case .conflict(let retained) = f.restore() else { Issue.record("Expected conflict at \(step) #\(occurrence)"); continue }
                #expect(retained.contains(unrecorded), "\(retained)")
                #expect(f.record != nil && f.journal.durable == f.record)
                #expect(try f.snapshot()[unrecorded] == before[unrecorded])
                if step == .afterStageCreate {
                    let name = NativeProxyRecord.fileNames[occurrence - 1]
                    if NativeProxyRecord.dllNames.contains(name) {
                        #expect(FileManager.default.fileExists(atPath: f.url(NativeProxyRecord.hiddenName(name, sessionID: f.sessionID)).path))
                    }
                }
                // Once the unknown artifact is resolved by someone else, recovery completes.
                try FileManager.default.removeItem(at: f.url(unrecorded))
            }
            #expect(f.restore() == .clean, "step \(step.rawValue) #\(occurrence)")
            #expect(f.journal.durable == nil)
            #expect(try f.snapshot() == baseline, "step \(step.rawValue) #\(occurrence)")
        }
    }

    @Test(arguments: NativeProxyFileStep.restoreSteps, [1, 2, 3])
    func crashDuringRestoreIsIdempotent(_ step: NativeProxyFileStep, occurrence: Int) throws {
        for useDurable in [true, false] {
            let f = try NativeProxyFixture()
            let baseline = try f.snapshot()
            try f.place()
            try Data("log".utf8).write(to: f.url("d3d11_log.txt"))
            let first = f.restore(NativeProxyFiles(hook: crashHook(at: step, occurrence: occurrence)))
            if first != .clean {
                guard case .pending = first else { Issue.record("Unexpected \(first)"); continue }
                if useDurable { f.record = f.journal.durable }
                #expect(f.record != nil)
                #expect(f.restore() == .clean, "step \(step.rawValue) #\(occurrence)")
            }
            #expect(f.record == nil && f.journal.durable == nil)
            #expect(try f.snapshot() == baseline, "step \(step.rawValue) #\(occurrence)")
        }
    }

    @Test func everyFailedJournalWriteDuringPlacementRecovers() throws {
        let total: Int
        do { let f = try NativeProxyFixture(); try f.place(); total = f.journal.writes }
        for failing in 0..<total {
            let f = try NativeProxyFixture()
            let baseline = try f.snapshot()
            f.journal.failAtWrite = failing
            #expect(throws: LauncherError.self) { try f.place() }
            if failing == 0 {
                // Nothing was durable and nothing was changed.
                #expect(try f.snapshot() == baseline)
            }
            f.journal.failAtWrite = nil
            #expect(f.restore() == .clean, "journal write \(failing)")
            #expect(try f.snapshot() == baseline, "journal write \(failing)")
        }
    }

    @Test func failedJournalWritesDuringRestoreRetainOwnership() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        for offset in 0..<16 {
            f.journal.failAtWrite = f.journal.writes + offset
            if f.restore() == .clean { break }
            #expect(f.record != nil && f.journal.durable != nil)
        }
        f.journal.failAtWrite = nil
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    @Test func failedRenameDuringPlacementRecovers() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        #expect(throws: (any Error).self) { try f.place(NativeProxyFiles(fileOps: LaunchFaultOps(failExclusive: true))) }
        #expect(f.record != nil)
        #expect(try Data(contentsOf: f.url("d3d11.dll")) == builtinD3D11)
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    @Test func failedUnlinkDuringRestoreIsPendingThenClean() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        // Removal unlinks only inside the private area, under a per-entry key.
        guard case .pending = f.restore(NativeProxyFiles(fileOps: NativeProxyUnlinkFailure(name: "link-Mods"))) else {
            Issue.record("Expected pending"); return
        }
        #expect(f.record != nil && f.journal.durable != nil)
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    // MARK: Primary review regressions

    /// P1: a removal that fails inside the private removal namespace must keep
    /// ownership until the quarantined inode is actually gone.
    @Test(arguments: 1...6) func helperUnlinkFailureRetainsOwnership(failing: Int) throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        try Data("log".utf8).write(to: f.url("d3d11_log.txt"))
        let first = f.restore(NativeProxyFiles(fileOps: try HelperUnlinkFailure(system32: f.system32, failAt: failing)))
        #expect(first != .clean, "helper unlink \(failing)")
        #expect(f.record != nil && f.journal.durable != nil, "helper unlink \(failing)")
        // A stale durable record must be enough to finish the job.
        f.record = f.journal.durable
        #expect(f.restore() == .clean, "helper unlink \(failing)")
        #expect(f.record == nil && f.journal.durable == nil)
        #expect(try f.snapshot() == baseline, "helper unlink \(failing)")
        try f.place()
        #expect(f.restore() == .clean)
    }

    /// P1: a foreign object substituted between the ownership check and removal
    /// of each public name is never deleted, and ownership is retained.
    @Test(arguments: ["Mods", "Core", "d3dx.ini", "d3d11.dll", "d3d11_log.txt"])
    func foreignSubstitutionAtRemovalIsRetained(name: String) throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        try Data("log".utf8).write(to: f.url("d3d11_log.txt"))
        let foreign = Data("FOREIGN \(name)".utf8)
        // An output is ours only while it is a single-link regular file.
        let alias = name == "d3d11_log.txt" ? f.root.appendingPathComponent("alias.txt").path : nil
        let ops = try SubstituteAtRemoval(system32: f.system32, name: name, foreign: foreign, alias: alias)
        guard case .conflict(let retained) = f.restore(NativeProxyFiles(fileOps: ops)) else {
            Issue.record("Expected conflict for \(name)"); return
        }
        #expect(ops.substituted)
        #expect(retained.contains(name), "\(retained)")
        #expect(try Data(contentsOf: f.url(name)) == foreign)
        #expect(f.record != nil && f.journal.durable != nil)
        if name.hasSuffix(".dll") {
            #expect(FileManager.default.fileExists(atPath: f.url(NativeProxyRecord.hiddenName(name, sessionID: f.sessionID)).path))
        }
        // Stable on retry; completes exactly once the foreign item is gone.
        guard case .conflict = f.restore() else { Issue.record("Expected stable conflict"); return }
        #expect(try Data(contentsOf: f.url(name)) == foreign)
        try FileManager.default.removeItem(at: f.url(name))
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    /// P1: a stage whose identity was never recorded is not ours by name alone.
    @Test(arguments: [true, false]) func unrecordedForeignStageIsRetained(useDurable: Bool) throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        let stageName = NativeProxyRecord.stageName("d3d11.dll", sessionID: f.sessionID)
        let stage = f.url(stageName), foreign = f.root.appendingPathComponent("foreign-stage")
        let foreignBytes = Data("foreign data".utf8)
        try foreignBytes.write(to: foreign)
        let stagePath = stage.path, foreignPath = foreign.path
        #expect(throws: SimulatedCrash.self) {
            try f.place(NativeProxyFiles(hook: { step in
                guard step == .afterStageCreate else { return }
                try FileManager.default.removeItem(atPath: stagePath)
                try FileManager.default.moveItem(atPath: foreignPath, toPath: stagePath)
                throw SimulatedCrash()
            }))
        }
        if useDurable {
            f.record = f.journal.durable
            #expect(f.record?.files[0].identity == nil)
        }
        guard case .conflict(let retained) = f.restore() else { Issue.record("Expected conflict"); return }
        #expect(retained.contains(stageName), "\(retained)")
        #expect(try Data(contentsOf: stage) == foreignBytes)
        #expect(f.record != nil && f.journal.durable != nil)
        #expect(try Data(contentsOf: f.url(NativeProxyRecord.hiddenName("d3d11.dll", sessionID: f.sessionID))) == builtinD3D11)
        try FileManager.default.removeItem(at: stage)
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    /// A foreign object raced into the private area after the claim rename is
    /// handed back to its vacant public name, never unlinked.
    @Test func foreignObjectInRemovalAreaIsReturned() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        let key = f.url(NativeProxyRecord.removalAreaName(sessionID: f.sessionID) + "/link-Mods").path
        let foreign = Data("FOREIGN in area".utf8)
        let seen = Mutex(false)
        let outcome = f.restore(NativeProxyFiles(hook: { step in
            guard step == .afterQuarantine, !seen.withLock({ let was = $0; $0 = true; return was }) else { return }
            try FileManager.default.removeItem(atPath: key)
            try foreign.write(to: URL(fileURLWithPath: key))
        }))
        guard case .conflict(let retained) = outcome else { Issue.record("Expected conflict"); return }
        #expect(retained.contains("Mods"), "\(retained)")
        #expect(try Data(contentsOf: f.url("Mods")) == foreign)
        #expect(f.record != nil && f.journal.durable != nil)
        try FileManager.default.removeItem(at: f.url("Mods"))
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    /// A replaced removal area is not adopted: nothing is claimed or unlinked.
    @Test func replacedRemovalAreaRetainsEverything() throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        try f.place()
        let areaName = NativeProxyRecord.removalAreaName(sessionID: f.sessionID)
        let area = f.url(areaName), moved = f.root.appendingPathComponent("moved-area")
        try FileManager.default.moveItem(at: area, to: moved)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("user".utf8).write(to: area.appendingPathComponent("user.txt"))
        let before = try f.snapshot()
        guard case .conflict(let retained) = f.restore() else { Issue.record("Expected conflict"); return }
        #expect(retained.contains(areaName) && retained.contains("Mods") && retained.contains("d3d11.dll"), "\(retained)")
        #expect(try f.snapshot() == before)
        #expect(f.record != nil && f.journal.durable == f.record)
        try FileManager.default.removeItem(at: area)
        try FileManager.default.moveItem(at: moved, to: area)
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
    }

    /// P2: a payload hard-linked after preflight is refused before publication.
    @Test(arguments: NativeProxyRecord.fileNames) func laterHardLinkedPayloadIsRefused(name: String) throws {
        let f = try NativeProxyFixture()
        let baseline = try f.snapshot()
        let payload = f.session.appendingPathComponent("payload/" + name)
        let alias = f.root.appendingPathComponent("alias-" + name)
        let payloadPath = payload.path, aliasPath = alias.path
        #expect(throws: (any Error).self) {
            try f.place(NativeProxyFiles(hook: { step in
                if step == .afterPlanPersist { try FileManager.default.linkItem(atPath: payloadPath, toPath: aliasPath) }
            }))
        }
        #expect(f.record != nil)
        #expect(f.record?.files.first(where: { $0.name == name })?.state != .placed)
        #expect(f.restore() == .clean)
        #expect(try f.snapshot() == baseline)
        #expect(FileManager.default.fileExists(atPath: alias.path))
    }
}

private func directoryKey(_ fd: Int32) -> (Int64, UInt64)? {
    var info = stat()
    guard fstat(fd, &info) == 0 else { return nil }
    return (Int64(info.st_dev), UInt64(info.st_ino))
}

private func pathKey(_ url: URL) throws -> (Int64, UInt64) {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw LauncherError.io("lstat") }
    return (Int64(info.st_dev), UInt64(info.st_ino))
}

/// Fails the Nth unlink performed outside system32 itself: the private
/// namespace of whichever removal helper is in use.
private final class HelperUnlinkFailure: FileOps, Sendable {
    private let system32: (Int64, UInt64)
    private let failAt: Int
    private let seen = Mutex(0)
    private let base = SystemFileOps()
    init(system32: URL, failAt: Int) throws { self.system32 = try pathKey(system32); self.failAt = failAt }
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
    }
    func unlink(_ entry: String, in dir: Int32, isDirectory: Bool) throws {
        if !isDirectory, let key = directoryKey(dir), key != system32 {
            let count = seen.withLock { $0 += 1; return $0 }
            if count == failAt { throw LauncherError.io("Injected helper unlink failure") }
        }
        try base.unlink(entry, in: dir, isDirectory: isDirectory)
    }
}

/// At the first rename or unlink of a public system32 name, replaces it with a
/// foreign regular file (optionally hard-linked elsewhere) just before the call.
private final class SubstituteAtRemoval: FileOps, Sendable {
    private let system32: (Int64, UInt64)
    private let name: String
    private let foreign: Data
    private let alias: String?
    private let done = Mutex(false)
    private let base = SystemFileOps()
    var substituted: Bool { done.withLock { $0 } }
    init(system32: URL, name: String, foreign: Data, alias: String?) throws {
        self.system32 = try pathKey(system32); self.name = name; self.foreign = foreign; self.alias = alias
    }
    private func substitute(_ entry: String, in dir: Int32) throws {
        guard entry == name, let key = directoryKey(dir), key == system32,
            !done.withLock({ let was = $0; $0 = true; return was }) else { return }
        guard unlinkat(dir, name, 0) == 0 else { throw LauncherError.io("substitute unlink") }
        let fd = openat(dir, name, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LauncherError.io("substitute create") }
        defer { close(fd) }
        try base.writeAll(foreign, to: fd)
        if let alias { guard linkat(dir, name, AT_FDCWD, alias, 0) == 0 else { throw LauncherError.io("substitute alias") } }
    }
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        try substitute(source, in: src)
        try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
    }
    func unlink(_ entry: String, in dir: Int32, isDirectory: Bool) throws {
        if !isDirectory { try substitute(entry, in: dir) }
        try base.unlink(entry, in: dir, isDirectory: isDirectory)
    }
}
