// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Darwin
import Synchronization
import Testing
import LauncherCore
import TestSupport
@testable import RuntimeManager

private let appKey = "HKCU\\Software\\Wine\\AppDefaults\\ZenlessZoneZero.exe"
private let overridesKey = appKey + "\\DllOverrides"
private let ours = "native,builtin"

@Suite(.timeLimit(.minutes(1))) struct NativeProxyOverrideTests {
    // MARK: ON

    @Test func freshOnRecordsOwnershipBeforeAddThenPersistsAndIsIdempotent() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            let first = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            #expect(first == NativeProxyOverrideOutcome(action: .applied, residualKeys: []))
            let events = fixture.log.events
            let owned = try #require(events.firstIndex(of: "marker publish owned"))
            let firstAdd = try #require(events.firstIndex(of: "reg add d3d11"))
            let secondAdd = try #require(events.firstIndex(of: "reg add d3dcompiler_47"))
            let barrier = try #require(events.firstIndex(of: "wineserver -w"))
            #expect(owned < firstAdd && firstAdd < secondAdd && secondAdd < barrier)
            #expect(events.firstIndex(of: "fsync user.reg").map { $0 > barrier } == true)
            for name in ["d3d11", "d3dcompiler_47"] { #expect(fixture.registry.value(overridesKey, name)?.data == ours) }
            let record = try #require(fixture.ownership())
            #expect(record["target"] as? String == "ZenlessZoneZero.exe" && record["game"] as? String == "zzz")
            #expect(record["createdAppKey"] as? Bool == true && record["createdOverridesKey"] as? Bool == true)
            #expect(!events.contains { $0.hasPrefix("reg delete") })

            let markerBefore = try fixture.markerData()
            fixture.log.reset()
            let second = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            #expect(second.action == .unchanged)
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg add") || $0.hasPrefix("reg delete") || $0.hasPrefix("marker") })
            #expect(try fixture.markerData() == markerBefore)
            #expect(fixture.log.events.contains("wineserver -w"))
        }
    }

    @Test(arguments: ["d3d11", "D3D11", "d3dcompiler_47"], [ours, "builtin", "native"])
    func unownedExistingValueFailsEvenWhenTextMatches(name: String, text: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            fixture.registry.seed(overridesKey, name, text)
            let before = try fixture.markerData()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg add") || $0.hasPrefix("reg delete") || $0.hasPrefix("marker") })
            #expect(try fixture.markerData() == before)
            #expect(fixture.registry.value(overridesKey, name)?.data == text)
        }
    }

    @Test func ownedValueChangedByAnotherActorIsAConflictOnBothDirections() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            fixture.registry.seed(overridesKey, "d3d11", "builtin")
            let before = try fixture.markerData()
            fixture.log.reset()
            for enabled in [true, false] {
                await #expect(throws: LauncherError.self) {
                    try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: enabled)
                }
            }
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg add") || $0.hasPrefix("reg delete") || $0.hasPrefix("marker") })
            #expect(fixture.registry.value(overridesKey, "d3d11")?.data == "builtin")
            #expect(fixture.registry.value(overridesKey, "d3dcompiler_47")?.data == ours)
            #expect(try fixture.markerData() == before)
        }
    }

    @Test func foreignTypeWithSameTextIsNotAdopted() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            fixture.registry.seed(overridesKey, "d3dcompiler_47", ours, type: "REG_EXPAND_SZ")
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            }
            #expect(fixture.registry.value(overridesKey, "d3dcompiler_47")?.type == "REG_EXPAND_SZ")
            #expect(fixture.ownership() != nil)
        }
    }

    // MARK: OFF

    @Test(arguments: ["zzz", "genshin"]) func offWithoutOwnershipMakesNoRunnerCallsAndNoWrites(game: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url, game: game)
            fixture.registry.seed(overridesKey, "d3d11", ours)   // foreign-looking value must be left alone
            let before = try fixture.markerData()
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome == NativeProxyOverrideOutcome(action: .unchanged, residualKeys: []))
            #expect(fixture.runner.invocations.isEmpty)
            #expect(fixture.log.events.isEmpty)
            #expect(try fixture.markerData() == before)
        }
    }

    @Test func offDeletesOwnedValuesPersistsThenClearsOwnershipAndRemovesCreatedKeys() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            fixture.registry.seedKey("HKCU\\Software\\Wine\\AppDefaults")
            fixture.registry.seed("HKCU\\Software\\Wine\\AppDefaults\\Other.exe\\DllOverrides", "ddraw", "native")
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            let provisioning = try fixture.markerJSON()["provisioningRevision"]
            fixture.log.reset()
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome == NativeProxyOverrideOutcome(action: .removed, residualKeys: []))
            let events = fixture.log.events
            let lastDelete = try #require(events.lastIndex { $0.hasPrefix("reg delete") })
            let barrier = try #require(events.firstIndex(of: "wineserver -w"))
            let registrySync = try #require(events.lastIndex(of: "fsync user.reg"))
            let clear = try #require(events.firstIndex(of: "marker publish plain"))
            #expect(lastDelete < barrier && barrier < registrySync && registrySync < clear)
            #expect(events.filter { $0.hasPrefix("reg delete-key") } == ["reg delete-key overrides", "reg delete-key app"])
            #expect(fixture.ownership() == nil)
            #expect(try fixture.markerJSON()["provisioningRevision"] as? Int == provisioning as? Int)
            #expect(!fixture.registry.hasKey(overridesKey) && !fixture.registry.hasKey(appKey))
            #expect(fixture.registry.hasKey("HKCU\\Software\\Wine\\AppDefaults"))
            #expect(fixture.registry.value("HKCU\\Software\\Wine\\AppDefaults\\Other.exe\\DllOverrides", "ddraw")?.data == "native")
            #expect(fixture.registry.recursiveDeletesOfNonEmptyKeys == 0)
        }
    }

    @Test func foreignSiblingValuesSurviveBothDirectionsAndPreexistingKeysStay() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            fixture.registry.seed(overridesKey, "dxgi", "builtin")
            fixture.registry.seed(appKey, "Version", "win10")
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            #expect(try #require(fixture.ownership())["createdOverridesKey"] as? Bool == false)
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome.action == .removed && outcome.residualKeys.isEmpty)
            #expect(fixture.registry.value(overridesKey, "dxgi")?.data == "builtin")
            #expect(fixture.registry.value(appKey, "Version")?.data == "win10")
            #expect(fixture.registry.value(overridesKey, "d3d11") == nil && fixture.registry.value(overridesKey, "d3dcompiler_47") == nil)
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg delete-key") })
        }
    }

    @Test(arguments: ["value", "subkey"]) func keysTheExperimentCreatedAreKeptWhenForeignContentAppeared(kind: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            if kind == "value" { fixture.registry.seed(overridesKey, "dxgi", "native") } else { fixture.registry.seedKey(overridesKey + "\\Child") }
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome.action == .removed)
            #expect(outcome.residualKeys == [overridesKey, appKey])
            #expect(fixture.registry.hasKey(overridesKey) && fixture.registry.hasKey(appKey))
            #expect(fixture.registry.value(overridesKey, "d3d11") == nil)
            if kind == "value" { #expect(fixture.registry.value(overridesKey, "dxgi")?.data == "native") } else { #expect(fixture.registry.hasKey(overridesKey + "\\Child")) }
            #expect(fixture.registry.recursiveDeletesOfNonEmptyKeys == 0)
            #expect(fixture.ownership() == nil)
        }
    }

    // MARK: Wine's empty-key protocol (headerless listings)

    /// Live regression: the two values were deleted, Wine then answered `reg query DllOverrides` with a
    /// lone CRLF (no header), the strict parser threw, and ownership/keys were never cleared.
    @Test func offRecoversWhenValuesAreGoneAndWineReportsTheEmptyKeyWithoutAHeader() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            for name in ["d3d11", "d3dcompiler_47"] { fixture.registry.removeValue(overridesKey, name) }
            fixture.log.reset()
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome == NativeProxyOverrideOutcome(action: .removed, residualKeys: []))
            let events = fixture.log.events
            #expect(!events.contains { $0.hasPrefix("reg delete d3d") })
            // Every key delete is preceded by an empty plain query and the /ve existence proof.
            for label in ["overrides", "app"] {
                let delete = try #require(events.firstIndex(of: "reg delete-key \(label)"))
                let confirm = try #require(events[..<delete].lastIndex(of: "reg query-ve \(label)"))
                #expect(events[..<confirm].last == "reg query \(label)")
            }
            #expect(!fixture.registry.hasKey(overridesKey) && !fixture.registry.hasKey(appKey))
            #expect(fixture.ownership() == nil)
            #expect(fixture.registry.recursiveDeletesOfNonEmptyKeys == 0)
        }
    }

    @Test func offIsIdempotentAfterTheEmptyKeysAreAlreadyGone() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            let failing = NativeProxyFixture.FailingMarkerClear()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep(fileOps: failing.wrap(fixture.audit)).reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            }
            #expect(fixture.ownership() != nil && !fixture.registry.hasKey(overridesKey) && !fixture.registry.hasKey(appKey))
            let retry = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(retry == NativeProxyOverrideOutcome(action: .removed, residualKeys: []))
            #expect(fixture.ownership() == nil)
        }
    }

    @Test(arguments: [
        (Int32(0), ""),
        (Int32(0), "\r\n"),
        (Int32(0), "\r\n" + overridesKey + "\r\n"),
        (Int32(0), "\r\nHKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\Other.exe\\DllOverrides\r\n    (Default)    REG_SZ    (value not set)\r\n"),
        (Int32(0), "\r\nHKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\ZenlessZoneZero.exe\\DllOverrides\r\n    (Default)    REG_SZ    set\r\n"),
        (Int32(0), "\r\nHKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\ZenlessZoneZero.exe\\DllOverrides\r\n    d3d11    REG_SZ    native,builtin\r\n"),
        (Int32(1), "reg: Unable to find the specified registry key\r\n"),
        (Int32(1), "reg: Access is denied\r\n"),
        (Int32(2), ""),
    ])
    func anEmptyAnswerIsNeverEnoughToDeleteAKey(exitCode: Int32, proof: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            let owned = try fixture.markerData()
            fixture.registry.overrideConfirmation(exitCode: exitCode, proof)
            fixture.log.reset()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            }
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg delete-key") })
            #expect(!fixture.log.events.contains("marker publish plain"))
            #expect(try fixture.markerData() == owned)
            #expect(fixture.registry.hasKey(overridesKey) && fixture.registry.hasKey(appKey))
            #expect(fixture.registry.recursiveDeletesOfNonEmptyKeys == 0)
        }
    }

    @Test func foreignSubkeyOnlyListingsHaveNoHeaderAndKeepBothKeys() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            fixture.registry.seed(overridesKey + "\\Foreign", "x", "y")
            fixture.registry.seedKey(appKey + "\\Other")
            fixture.log.reset()
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome == NativeProxyOverrideOutcome(action: .removed, residualKeys: [overridesKey, appKey]))
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg delete-key") || $0.hasPrefix("reg query-ve") })
            #expect(fixture.registry.value(overridesKey + "\\Foreign", "x")?.data == "y" && fixture.registry.hasKey(appKey + "\\Other"))
            #expect(fixture.registry.recursiveDeletesOfNonEmptyKeys == 0 && fixture.ownership() == nil)
        }
    }

    @Test func preexistingAppKeyHoldingOnlyForeignSubkeysIsNeverCreatedOrRemoved() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            fixture.registry.seedKey(appKey + "\\X11 Driver")
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            let record = try #require(fixture.ownership())
            #expect(record["createdAppKey"] as? Bool == false && record["createdOverridesKey"] as? Bool == true)
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome == NativeProxyOverrideOutcome(action: .removed, residualKeys: []))
            #expect(!fixture.registry.hasKey(overridesKey) && fixture.registry.hasKey(appKey + "\\X11 Driver"))
            #expect(fixture.registry.recursiveDeletesOfNonEmptyKeys == 0)
        }
    }

    @Test func preexistingEmptyOverridesKeyIsRecordedAsNotCreatedAndStays() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            fixture.registry.seedKey(overridesKey)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            let record = try #require(fixture.ownership())
            #expect(record["createdAppKey"] as? Bool == false && record["createdOverridesKey"] as? Bool == false)
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome == NativeProxyOverrideOutcome(action: .removed, residualKeys: []))
            #expect(fixture.registry.hasKey(overridesKey) && fixture.registry.hasKey(appKey))
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg delete-key") })
        }
    }

    // MARK: Identity and validation

    @Test func legacyMarkersDecodeWithoutOwnershipAndEnableFailsClosed() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            let original = try fixture.markerData()
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let marker = try decoder.decode(PrefixMarker.self, from: original)
            #expect(marker.nativeProxyOverrides == nil)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            #expect(!String(decoding: try encoder.encode(marker), as: UTF8.self).contains("nativeProxyOverrides"))
            try fixture.setMarker { $0.removeValue(forKey: "game"); $0.removeValue(forKey: "state") }
            let legacy = try fixture.markerData()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(fixture.runner.invocations.isEmpty)
            #expect(try fixture.markerData() == legacy)
        }
    }

    @Test(arguments: ["genshin", "zzz-cn", "starrail"]) func onlyGlobalZZZMarkerIdentityIsAccepted(game: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try fixture.setMarker { $0["game"] = game }
            let before = try fixture.markerData()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(fixture.runner.invocations.isEmpty)
            #expect(try fixture.markerData() == before)
        }
    }

    @Test func directoryNameAloneNeverEstablishesZZZ() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url, game: "genshin")
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(fixture.runner.invocations.isEmpty)
        }
    }

    @Test(arguments: [
        "target", "extraValue", "valueText", "schema", "gameName", "appWithoutOverrides", "emptyValues", "caseVariantName"
    ]) func invalidOwnershipRecordsAreRejectedWithoutAnyRegistryAccess(mutation: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            try fixture.setMarker { marker in
                var record = marker["nativeProxyOverrides"] as! [String: Any]
                var values = record["values"] as! [String: String]
                switch mutation {
                case "target": record["target"] = "StarRail.exe"
                case "extraValue": values["dxgi"] = ours
                case "valueText": values["d3d11"] = "native"
                case "schema": record["schemaVersion"] = 2
                case "gameName": record["game"] = "genshin"
                case "appWithoutOverrides": record["createdAppKey"] = true; record["createdOverridesKey"] = false
                case "emptyValues": values = [:]
                default: values["D3D11"] = values.removeValue(forKey: "d3d11")
                }
                record["values"] = values
                marker["nativeProxyOverrides"] = record
            }
            let before = try fixture.markerData()
            fixture.runner.clear()
            for enabled in [true, false] {
                await #expect(throws: LauncherError.self) {
                    try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: enabled)
                }
            }
            #expect(fixture.runner.invocations.isEmpty)
            #expect(try fixture.markerData() == before)
            #expect(fixture.registry.value(overridesKey, "d3d11")?.data == ours)
        }
    }

    @Test(arguments: ["ready-state", "wine-path", "wine-identity"]) func requiresReadyMarkerForThisWine(mutation: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try fixture.setMarker { marker in
                switch mutation {
                case "ready-state": marker["state"] = "upgrading"
                case "wine-path": marker["wineBinaryPath"] = "/elsewhere/wine"
                default: try? fixture.fs.writeAtomically(Data("replaced wine".utf8), to: SafeRelativePath("Runtimes/bundle/bin/wine"))
                }
            }
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(fixture.runner.invocations.isEmpty)
        }
    }

    @Test func busyOrUnverifiablePrefixIsRefusedBeforeAnyRunnerCall() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            fixture.runner.clear()
            let before = try fixture.markerData()
            let busy = IdlePrefixInspector(inspect: { [InspectedProcess(identity: ProcessIdentity(pid: 9, startTime: 1), executablePath: "/runtime/bin/wine", arguments: ["Game.exe"])] })
            let ambiguous = IdlePrefixInspector(inspect: { throw ProcessInspectionError.incompleteScan })
            for (inspector, enabled) in [(busy, true), (busy, false), (ambiguous, true), (ambiguous, false)] {
                await #expect(throws: LauncherError.self) {
                    try await fixture.prep(inspector: inspector).reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: enabled)
                }
            }
            #expect(fixture.runner.invocations.isEmpty)
            #expect(try fixture.markerData() == before)
        }
    }

    @Test func wineUpgradeKeepsOwnershipSoCleanupStillWorks() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            try fixture.fs.writeAtomically(Data("wine v2".utf8), to: SafeRelativePath("Runtimes/bundle/bin/wine"))
            _ = try await PrefixManager(paths: fixture.paths, runner: FakeProcessRunner(), inspector: IdlePrefixInspector())
                .createPrefix(game: "zzz", backend: .d3dmetal, wineBinary: fixture.wine)
            #expect(fixture.ownership() != nil)
            #expect(try fixture.markerJSON()["provisioningRevision"] == nil)
            let outcome = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(outcome.action == .removed && fixture.ownership() == nil)
            #expect(!fixture.registry.hasKey(appKey))
        }
    }

    @Test(arguments: ["wrong-type", "invalid-record", "unsupported-marker-schema"])
    func malformedOwnedMarkerNeverResetsAnExistingPrefix(mutation: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            try fixture.setMarker { marker in
                if mutation == "wrong-type" {
                    marker["nativeProxyOverrides"] = "malformed"
                } else if mutation == "unsupported-marker-schema" {
                    marker["schemaVersion"] = 999
                } else {
                    var owned = marker["nativeProxyOverrides"] as! [String: Any]
                    owned["target"] = "Other.exe"
                    marker["nativeProxyOverrides"] = owned
                }
            }
            let before = try fixture.markerData()
            let sentinel = try SafeRelativePath("Prefixes/zzz-d3dmetal/preserve-me.txt")
            try fixture.fs.writeAtomically(Data("owned-prefix-data".utf8), to: sentinel)
            let runner = FakeProcessRunner()
            await #expect(throws: LauncherError.self) {
                _ = try await PrefixManager(paths: fixture.paths, runner: runner, inspector: IdlePrefixInspector())
                    .createPrefix(game: "zzz", backend: .d3dmetal, wineBinary: fixture.wine)
            }
            #expect(runner.invocations.isEmpty)
            #expect(try fixture.markerData() == before)
            #expect(try fixture.fs.readFile(at: sentinel, maxBytes: 100) == Data("owned-prefix-data".utf8))
        }
    }

    @Test func oversizedOwnedMarkerNeverResetsAnExistingPrefix() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            let oversized = try fixture.markerData() + Data(repeating: 0x20, count: 16_385)
            try fixture.fs.writeAtomically(oversized, to: fixture.markerRelative)
            let sentinel = try SafeRelativePath("Prefixes/zzz-d3dmetal/preserve-me.txt")
            try fixture.fs.writeAtomically(Data("keep".utf8), to: sentinel)
            let runner = FakeProcessRunner()
            await #expect(throws: LauncherError.self) {
                _ = try await PrefixManager(paths: fixture.paths, runner: runner, inspector: IdlePrefixInspector())
                    .createPrefix(game: "zzz", backend: .d3dmetal, wineBinary: fixture.wine)
            }
            #expect(runner.invocations.isEmpty)
            #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent(".macgacha-prefix.json")) == oversized)
            #expect(try fixture.fs.readFile(at: sentinel, maxBytes: 100) == Data("keep".utf8))
        }
    }

    // MARK: Interruption and failure

    @Test func markerFailureBeforeAddLeavesRegistryUntouchedAndUnowned() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url, failSync: "pending")
            let before = try fixture.markerData()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg add") })
            #expect(fixture.ownership() == nil)
            #expect(try fixture.markerData() == before)
        }
    }

    @Test(arguments: ["reg add d3d11", "reg add d3dcompiler_47", "wineserver -w", "fsync user.reg"])
    func interruptionAfterOwnershipKeepsCleanupAndRetryRecovers(failure: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url, failSync: failure.hasPrefix("fsync") ? "user.reg" : nil)
            if !failure.hasPrefix("fsync") { fixture.registry.failOnce(failure, exitCode: 7) }
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(fixture.ownership() != nil)
            // OFF must clean whatever subset landed, treating missing values as already gone.
            fixture.syncFailure.clear()
            let off = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(off.action == .removed && fixture.ownership() == nil)
            #expect(!fixture.registry.hasKey(overridesKey) && !fixture.registry.hasKey(appKey))
            // And ON can start over from the clean state.
            let on = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            #expect(on.action == .applied)
        }
    }

    @Test func retryAfterPartialAddOnlyAddsTheMissingValue() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            fixture.registry.failOnce("reg add d3dcompiler_47", exitCode: 7)
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            fixture.log.reset()
            let retry = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            #expect(retry.action == .applied)
            #expect(fixture.log.events.filter { $0.hasPrefix("reg add") } == ["reg add d3dcompiler_47"])
            #expect(!fixture.log.events.contains("marker publish owned"))
            #expect(fixture.registry.value(overridesKey, "d3d11")?.data == ours)
        }
    }

    @Test(arguments: ["wineserver -w", "fsync user.reg", "reg delete d3d11", "reg delete-key overrides"])
    func offFailureBeforeDurabilityKeepsOwnership(failure: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            let owned = try fixture.markerData()
            fixture.log.reset()
            if failure.hasPrefix("fsync") { fixture.syncFailure.set("user.reg") } else { fixture.registry.failOnce(failure, exitCode: 5) }
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            }
            #expect(try fixture.markerData() == owned)
            #expect(!fixture.log.events.contains("marker publish plain"))
            fixture.syncFailure.clear()
            let retry = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(retry.action == .removed && fixture.ownership() == nil)
        }
    }

    @Test func crashBetweenPersistenceAndOwnershipClearIsRecoverable() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            let failing = NativeProxyFixture.FailingMarkerClear()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep(fileOps: failing.wrap(fixture.audit)).reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            }
            #expect(fixture.ownership() != nil)
            #expect(fixture.registry.value(overridesKey, "d3d11") == nil)
            let retry = try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: false)
            #expect(retry.action == .removed && fixture.ownership() == nil)
        }
    }

    @Test(arguments: [1, 2, 127]) func queryFailureIsNeverTreatedAsMissing(exitCode: Int32) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            fixture.registry.failQueries(exitCode: exitCode, stderr: exitCode == 1 ? "reg: Access is denied" : "boom")
            let before = try fixture.markerData()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg add") || $0.hasPrefix("marker") })
            #expect(try fixture.markerData() == before)
        }
    }

    @Test func unreadableOrUnparseableQueryOutputFailsClosed() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            fixture.registry.garbleQueries()
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg add") || $0.hasPrefix("marker") })
        }
    }

    @Test(arguments: ["HKgarbage\n", "HKCU\\Software\\Unrelated\n",
        overridesKey + "\nHKCU\\Software\\Unrelated\n"])
    func wrongRegistryHeaderNeverMutatesOwnershipOrValues(output: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await NativeProxyFixture(root: temp.url)
            let before = try fixture.markerData()
            fixture.registry.overrideQueryOutput(output)
            await #expect(throws: LauncherError.self) {
                try await fixture.prep().reconcileNativeProxyOverrides(prefix: fixture.prefix, wineBinary: fixture.wine, enabled: true)
            }
            #expect(try fixture.markerData() == before)
            #expect(!fixture.log.events.contains { $0.hasPrefix("reg add") || $0.hasPrefix("reg delete") || $0.hasPrefix("marker") })
        }
    }

    @Test func parserReadsWineListingsAndRejectsNoise() {
        let text = "\r\nHKEY_CURRENT_USER\\Software\\Wine\\X\r\n    d3d11    REG_SZ    native,builtin\r\n    my value    REG_DWORD    0x1\r\n    empty    REG_SZ    \r\n\r\nHKEY_CURRENT_USER\\Software\\Wine\\X\\Sub\r\n"
        let listing = NativeProxyOverrideTests.parse(text)
        #expect(listing?.subkeyCount == 1)
        #expect(listing?.values.map(\.name) == ["d3d11", "my value", "empty"])
        #expect(listing?.values.first?.data == "native,builtin" && listing?.values.last?.data == "")
        #expect(Self.parse("hKcU\\SOFTWARE\\wine\\x\nHKEY_CURRENT_USER\\Software\\Wine\\X\\Sub\n")?.subkeyCount == 1)
        for bad in ["garbage\n", "    d3d11    REG_SZ    x\n", "HKEY_X\n    no type here\n", "HKEY_X\n    n    notatype    x\n"] {
            #expect(NativeProxyOverrideTests.parse(bad) == nil)
        }
    }

    /// Bytes captured from Wine 11.20 reg.exe against a disposable prefix.
    @Test func parserReadsWineHeaderlessListingsAndStillRejectsMismatches() {
        let x = "HKEY_CURRENT_USER\\Software\\Wine\\X"
        // Key with neither values nor subkeys: a lone CRLF. The parser reports empty; the caller must prove existence.
        for empty in ["\r\n", "", " \r\n\r\n"] { #expect(Self.parse(empty) == RegistryKeyListing(values: [], subkeyCount: 0)) }
        // Key with subkeys only: no header, just the child paths (any case for the queried prefix).
        let children = Self.parse("\r\n" + x + "\\Alpha\r\n" + x.lowercased() + "\\Zeta\r\n")
        #expect(children == RegistryKeyListing(values: [], subkeyCount: 2))
        // Header, values, blank line, then subkeys.
        let mixed = Self.parse("\r\n" + x + "\r\n    (Default)    REG_SZ    dflt\r\n\r\n" + x + "\\Alpha\r\n")
        #expect(mixed?.values.map(\.name) == ["(Default)"] && mixed?.subkeyCount == 1)
        #expect(Self.parse("\r\n" + x + "\r\n    (Default)    REG_SZ    (value not set)\r\n")?.values.count == 1)
        for bad in [
            "\r\n" + x + "\\Alpha\\Deeper\r\n",                                  // not a direct child
            "\r\nHKEY_CURRENT_USER\\Software\\Wine\\Y\\Alpha\r\n",                  // child of a different key
            "\r\n" + x + "\\Alpha\r\n" + x + "\\Alpha\r\n",                        // duplicate child
            "\r\n" + x + "\\Alpha\r\n" + x + "\r\n",                                // header after a child
            "\r\n" + x + "\r\n" + x + "\r\n",                                       // two headers
            "\r\n" + x + "\\Alpha\r\n    n    REG_SZ    v\r\n",                    // value after a child
            "\r\n    n    REG_SZ    v\r\n",                                       // value without a header
            "\r\nreg: Unable to find the specified registry key\r\n",              // diagnostic is not a listing
        ] { #expect(Self.parse(bad) == nil, "\(bad.debugDescription)") }
    }

    private static func parse(_ text: String) -> RegistryKeyListing? {
        LaunchPreparation.parseKeyListing(text, expectedKey: "HKCU\\Software\\Wine\\X")
    }
}

// MARK: - Fixtures

private final class EventLog: Sendable {
    private let items = Mutex([String]())
    var events: [String] { items.withLock { $0 } }
    func add(_ event: String) { items.withLock { $0.append(event) } }
    func reset() { items.withLock { $0.removeAll() } }
}

private final class SyncFailure: Sendable {
    private let leaf = Mutex<String?>(nil)
    init(_ value: String?) { leaf.withLock { $0 = value } }
    func clear() { leaf.withLock { $0 = nil } }
    func set(_ value: String) { leaf.withLock { $0 = value } }
    var value: String? { leaf.withLock { $0 } }
}

private struct RegValue: Sendable { var name: String, type: String, data: String }

/// In-memory stand-in for Wine's reg.exe. Key and value names are case-insensitive.
private final class FakeWineRegistry: Sendable {
    private struct State: Sendable {
        var keys: [String: [String: RegValue]] = [:]
        var displayNames: [String: String] = [:]
        var failOnce: [String: Int32] = [:]
        var queryFailure: (Int32, String)? = nil
        var garble = false
        var queryOutput: String? = nil
        var confirmation: (Int32, String)? = nil
        var recursiveDeletes = 0
    }
    private let state = Mutex(State())
    let log: EventLog
    init(log: EventLog) { self.log = log }

    private static func norm(_ key: String) -> String { key.lowercased() }
    private static func ancestors(_ key: String) -> [String] {
        let parts = key.split(separator: "\\").map(String.init)
        return (1...parts.count).map { parts[0..<$0].joined(separator: "\\") }
    }

    func seedKey(_ key: String) { state.withLock { s in for k in Self.ancestors(key) where s.keys[Self.norm(k)] == nil { s.keys[Self.norm(k)] = [:]; s.displayNames[Self.norm(k)] = k } } }
    func seed(_ key: String, _ name: String, _ data: String, type: String = "REG_SZ") {
        seedKey(key)
        state.withLock { $0.keys[Self.norm(key), default: [:]][name.lowercased()] = RegValue(name: name, type: type, data: data) }
    }
    func hasKey(_ key: String) -> Bool { state.withLock { $0.keys[Self.norm(key)] != nil } }
    func value(_ key: String, _ name: String) -> (type: String, data: String)? {
        state.withLock { $0.keys[Self.norm(key)]?[name.lowercased()].map { ($0.type, $0.data) } }
    }
    func failOnce(_ label: String, exitCode: Int32) { state.withLock { $0.failOnce[label] = exitCode } }
    func failQueries(exitCode: Int32, stderr: String) { state.withLock { $0.queryFailure = (exitCode, stderr) } }
    func garbleQueries() { state.withLock { $0.garble = true } }
    func overrideQueryOutput(_ text: String) { state.withLock { $0.queryOutput = text } }
    /// Replaces the answer to `reg query KEY /ve`, Wine's proof that an otherwise empty key exists.
    func overrideConfirmation(exitCode: Int32 = 0, _ text: String) { state.withLock { $0.confirmation = (exitCode, text) } }
    func removeValue(_ key: String, _ name: String) { state.withLock { _ = $0.keys[Self.norm(key)]?.removeValue(forKey: name.lowercased()) } }
    var recursiveDeletesOfNonEmptyKeys: Int { state.withLock { $0.recursiveDeletes } }

    private static func label(_ key: String) -> String {
        key.lowercased().hasSuffix("dlloverrides") ? "overrides" : key.lowercased().hasSuffix("zenlesszonezero.exe") ? "app" : key
    }
    /// Captured from Wine 11.20 reg.exe: the diagnostic is on stdout, CRLF terminated, exit 1.
    private static let missing = ProcessResult(exitCode: 1, stdout: Data("reg: Unable to find the specified registry key\r\n".utf8), stderr: Data())
    private static let ok = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())

    func handle(_ call: FakeProcessRunner.Invocation) -> ProcessResult {
        let args = call.arguments
        if call.executable.lastPathComponent == "wineserver" { return respond("wineserver -w") ?? Self.ok }
        guard args.first == "reg", args.count >= 3 else { log.add("unexpected \(args)"); return ProcessResult(exitCode: 2, stdout: Data(), stderr: Data()) }
        let key = args[2], norm = Self.norm(key)
        switch args[1] {
        case "query":
            let confirmation = args.dropFirst(3).contains("/ve")
            log.add("reg query\(confirmation ? "-ve" : "") \(Self.label(key))")
            return state.withLock { s in
                if let failure = s.queryFailure { return ProcessResult(exitCode: failure.0, stdout: Data(), stderr: Data(failure.1.utf8)) }
                if confirmation, let override = s.confirmation { return ProcessResult(exitCode: override.0, stdout: Data(override.1.utf8), stderr: Data()) }
                if !confirmation, s.garble { return ProcessResult(exitCode: 0, stdout: Data("???\n".utf8), stderr: Data()) }
                if !confirmation, let output = s.queryOutput { return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data()) }
                guard let values = s.keys[norm] else { return Self.missing }
                // Wine 11.20 protocol: the header only exists when the key has values; subkeys follow
                // as bare full paths; a key with neither prints a lone blank line. All CRLF.
                var out = "\r\n"
                if confirmation {
                    out += "\(key)\r\n    (Default)    REG_SZ    (value not set)\r\n"
                    return ProcessResult(exitCode: 0, stdout: Data(out.utf8), stderr: Data())
                }
                if !values.isEmpty {
                    out += "\(key)\r\n"
                    for value in values.values.sorted(by: { $0.name < $1.name }) { out += "    \(value.name)    \(value.type)    \(value.data)\r\n" }
                    out += "\r\n"
                }
                for child in s.keys.keys.sorted() where child.hasPrefix(norm + "\\") && !child.dropFirst(norm.count + 1).contains("\\") {
                    out += "\(key + "\\" + (s.displayNames[child] ?? child).split(separator: "\\").last!)\r\n"
                }
                return ProcessResult(exitCode: 0, stdout: Data(out.utf8), stderr: Data())
            }
        case "add":
            let name = args[args.firstIndex(of: "/v")! + 1], type = args[args.firstIndex(of: "/t")! + 1], data = args[args.firstIndex(of: "/d")! + 1]
            if let failure = respond("reg add \(name.lowercased())") { return failure }
            seedKey(key)
            state.withLock { $0.keys[norm, default: [:]][name.lowercased()] = RegValue(name: name, type: type, data: data) }
            return Self.ok
        case "delete":
            if let index = args.firstIndex(of: "/v") {
                let name = args[index + 1]
                if let failure = respond("reg delete \(name.lowercased())") { return failure }
                return state.withLock { s in
                    guard s.keys[norm]?.removeValue(forKey: name.lowercased()) != nil else { return Self.missing }
                    return Self.ok
                }
            }
            let label = "reg delete-key \(Self.label(key))"
            if let failure = respond(label) { return failure }
            return state.withLock { s in
                guard let values = s.keys[norm] else { return Self.missing }
                let descendants = s.keys.keys.filter { $0.hasPrefix(norm + "\\") }
                if !values.isEmpty || !descendants.isEmpty { s.recursiveDeletes += 1 }
                for descendant in descendants { s.keys.removeValue(forKey: descendant) }
                s.keys.removeValue(forKey: norm)
                return Self.ok
            }
        default:
            log.add("unexpected \(args)"); return ProcessResult(exitCode: 2, stdout: Data(), stderr: Data())
        }
    }

    private func respond(_ label: String) -> ProcessResult? {
        log.add(label)
        guard let code = state.withLock({ $0.failOnce.removeValue(forKey: label) }) else { return nil }
        return ProcessResult(exitCode: code, stdout: Data(), stderr: Data("injected".utf8))
    }
}

private final class AuditFileOps: FileOps, Sendable {
    let log: EventLog, failure: SyncFailure
    init(log: EventLog, failure: SyncFailure) { self.log = log; self.failure = failure }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        let text = String(decoding: bytes, as: UTF8.self)
        if text.contains("\"backend\"") { log.add(text.contains("\"nativeProxyOverrides\"") ? "marker write owned" : "marker write plain") }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard buffer.withUnsafeMutableBufferPointer({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0 else {
            throw LauncherError.io("Cannot inspect persistence test descriptor")
        }
        let leaf = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).lastPathComponent
        if ["system.reg", "user.reg", "userdef.reg"].contains(leaf) { #expect(!durable); log.add("fsync " + leaf) }
        else if leaf == ".macgacha-prefix.pending" { #expect(durable); log.add("fullsync marker") }
        if let target = failure.value, target == leaf || (target == "pending" && leaf == ".macgacha-prefix.pending") {
            throw LauncherError.io("Injected sync failure")
        }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        if destination == ".macgacha-prefix.json" { log.add("marker publish " + (lastWrite() )) }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
    private func lastWrite() -> String {
        log.events.last { $0.hasPrefix("marker write") }.map { $0.hasSuffix("owned") ? "owned" : "plain" } ?? "plain"
    }
}

private struct NativeProxyFixture: Sendable {
    let paths: AppPaths, fs: ContainedFileSystem, wine: URL, prefix: URL
    let log = EventLog(), syncFailure: SyncFailure, runner: RecordingRunner
    let registry: FakeWineRegistry, audit: AuditFileOps
    let markerRelative: SafeRelativePath

    init(root: URL, game: String = "zzz", failSync: String? = nil) async throws {
        paths = AppPaths(root: root); fs = try ContainedFileSystem(root: root)
        wine = root.appendingPathComponent("Runtimes/bundle/bin/wine")
        try fs.writeAtomically(Data("wine".utf8), to: SafeRelativePath("Runtimes/bundle/bin/wine"))
        try fs.writeAtomically(Data("wineserver".utf8), to: SafeRelativePath("Runtimes/bundle/bin/wineserver"))
        prefix = try await PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: IdlePrefixInspector())
            .createPrefix(game: game, backend: .d3dmetal, wineBinary: wine)
        for name in ["system.reg", "user.reg", "userdef.reg"] { try fs.writeAtomically(Data("registry".utf8), to: SafeRelativePath("Prefixes/\(game)-d3dmetal/\(name)")) }
        markerRelative = try SafeRelativePath("Prefixes/\(game)-d3dmetal/.macgacha-prefix.json")
        syncFailure = SyncFailure(failSync)
        registry = FakeWineRegistry(log: log)
        runner = RecordingRunner(registry)
        audit = AuditFileOps(log: log, failure: syncFailure)
    }

    func prep(inspector: IdlePrefixInspector = IdlePrefixInspector(), fileOps: (any FileOps)? = nil) -> LaunchPreparation {
        LaunchPreparation(paths: paths, runner: runner, fileOps: fileOps ?? audit, inspector: inspector)
    }
    func markerData() throws -> Data { try fs.readFile(at: markerRelative, maxBytes: 16_384) }
    func markerJSON() throws -> [String: Any] { try JSONSerialization.jsonObject(with: markerData()) as! [String: Any] }
    func ownership() -> [String: Any]? { (try? markerJSON())?["nativeProxyOverrides"] as? [String: Any] }
    func setMarker(_ mutate: (inout [String: Any]) throws -> Void) throws {
        var json = try markerJSON(); try mutate(&json)
        try fs.writeAtomically(JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), to: markerRelative)
    }

    /// Fails the plain (ownership-clearing) marker sync once while leaving the registry work intact.
    final class FailingMarkerClear: Sendable {
        private let armed = Mutex(true)
        func wrap(_ base: AuditFileOps) -> any FileOps { Wrapper(base: base, owner: self) }
        fileprivate func shouldFail() -> Bool { armed.withLock { let value = $0; $0 = false; return value } }
        private struct Wrapper: FileOps {
            let base: AuditFileOps, owner: FailingMarkerClear
            func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(descriptor, bytes: bytes) }
            func synchronize(_ descriptor: Int32, durable: Bool) throws {
                if durable, base.log.events.last == "marker write plain", owner.shouldFail() { throw LauncherError.io("Injected crash before clear") }
                try base.synchronize(descriptor, durable: durable)
            }
            func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
                try base.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
            }
            func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try base.unlink(name, in: directory, isDirectory: isDirectory) }
        }
    }
}

/// FakeProcessRunner dispatching to the fake registry while remembering every call.
private final class RecordingRunner: ProcessRunner, Sendable {
    private let inner: FakeProcessRunner
    private let cleared = Mutex(0)
    init(_ registry: FakeWineRegistry) { inner = FakeProcessRunner { registry.handle($0) } }
    var invocations: [FakeProcessRunner.Invocation] { let skip = cleared.withLock { $0 }; return Array(inner.invocations.dropFirst(skip)) }
    func clear() { cleared.withLock { $0 = inner.invocations.count } }
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        try await inner.run(executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
    }
}
