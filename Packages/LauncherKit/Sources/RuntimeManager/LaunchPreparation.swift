// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Idempotent provisioning of an initialized prefix. Wine registry settings
/// and verified file copies stay in this prefix; no certificates are installed.
/// Shares PrefixManager's lock so initialization and preparation cannot overlap.
public struct LaunchPreparation: Sendable {
    public static let provisioningRevision = 3
    private let paths: AppPaths
    private let runner: any ProcessRunner
    private let inspector: any ProcessInspector
    private let serverProbe: WineServerProbe
    private let fileOps: any FileOps
    private let registryWaitTimeout: Duration
    private let timeoutWait: @Sendable (Duration) async throws -> Void
    private static let internetSettings = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"

    public init(paths: AppPaths, runner: any ProcessRunner, registryWaitTimeout: Duration = .seconds(60),
        inspector: any ProcessInspector = SystemProcessInspector(), wineServerRoot: URL? = nil) {
        self.init(paths: paths, runner: runner, fileOps: SystemFileOps(), registryWaitTimeout: registryWaitTimeout, inspector: inspector, wineServerRoot: wineServerRoot)
    }

    package init(paths: AppPaths, runner: any ProcessRunner, fileOps: any FileOps,
        registryWaitTimeout: Duration = .seconds(60),
        timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        inspector: any ProcessInspector = SystemProcessInspector(), wineServerRoot: URL? = nil) {
        self.paths = paths; self.runner = runner; self.fileOps = fileOps; self.inspector = inspector
        self.serverProbe = WineServerProbe(root: wineServerRoot)
        self.registryWaitTimeout = registryWaitTimeout; self.timeoutWait = timeoutWait
    }

    @discardableResult public func ensure(prefix: URL, wineBinary: URL, request: PreparationRequest) async throws -> PreparationOutcome {
        do {
            return try await BlockingIO.run { try await ensureOnIO(prefix: prefix, wineBinary: wineBinary, request: request) }
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func ensureOnIO(prefix: URL, wineBinary: URL, request: PreparationRequest) async throws -> PreparationOutcome {
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        let path = try RuntimeJSONFile.relativePath(prefix, root: paths.root)
        guard path.components.count == 2, path.components.first == "Prefixes" else { throw LauncherError.unsafePath(prefix.path) }
        _ = try SafeIdentifier(path.components[1])
        _ = try fs.directoryURL(at: path)
        let lock = try await PrefixManager.acquireLock(fs: fs, prefix: path)
        defer { withExtendedLifetime(lock) {} }
        let markerPath = try SafeRelativePath("\(path)/.macgacha-prefix.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var marker = try decoder.decode(PrefixMarker.self, from: fs.readFile(at: markerPath, maxBytes: PrefixManager.markerLimit))
        let binary = wineBinary.standardizedFileURL
        let sourceRoot = binary.deletingLastPathComponent()
        let sourceFS = try ContainedFileSystem(root: sourceRoot)
        let sourcePath = try RuntimeJSONFile.relativePath(binary, root: sourceRoot)
        let binaryIdentity = try fingerprint(sourceFS, at: sourcePath).digest
        guard marker.schemaVersion == PrefixMarker.schema, marker.state == .ready,
              marker.createdAt.timeIntervalSince1970.isFinite, marker.wineBinaryPath == binary.path,
              marker.wineBinaryIdentity == binaryIdentity else {
            throw LauncherError.io("Launch preparation requires a ready prefix for this Wine binary")
        }
        for name in request.dxmtExtras {
            guard try SafeRelativePath(name).components.count == 1 else { throw LauncherError.unsafePath(name) }
        }
        guard let prefixFS = try fs.pinDirectoryIfPresent(at: path) else { throw LauncherError.io("Prefix is missing") }
        try PrefixShellFolders.validate(in: prefixFS)
        try PrefixShellFolders.requireIdle(prefix: prefix, prefixFS: prefixFS, wineBinary: binary, runtimeRoot: paths.runtimes, inspector: inspector, serverProbe: serverProbe)
        try PrefixShellFolders.repair(in: prefixFS)
        let environment = PrefixManager.preparationEnvironment(prefix: prefix)
        let needsProvisioning = (marker.provisioningRevision ?? 0) < Self.provisioningRevision
        if needsProvisioning {
            try await run(binary, ["reg", "add", Self.internetSettings, "/v", "ProxyEnable", "/t", "REG_DWORD", "/d", "0", "/f"], environment)
            for value in ["ProxyServer", "ProxyOverride"] {
                try await run(binary, ["reg", "delete", Self.internetSettings, "/v", value, "/f"], environment, allowMissingValue: true)
            }
            try await run(binary, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "winemenubuilder.exe", "/t", "REG_SZ", "/d", "", "/f"], environment)
            for (value, folder) in PrefixShellFolders.registryValues {
                try await run(binary, ["reg", "add", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders",
                    "/v", value, "/t", "REG_EXPAND_SZ", "/d", "%USERPROFILE%\\" + folder, "/f"], environment)
            }
        }
        try await run(binary, ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", "RetinaMode", "/t", "REG_SZ", "/d", request.retina ? "y" : "n", "/f"], environment)
        // Apply per launch even to an already prepared prefix. The persistence
        // barrier below must succeed before launch or revision publication.
        if let version = request.windowsVersion {
            try await run(binary, ["reg", "add", "HKCU\\Software\\Wine", "/v", "Version", "/t", "REG_SZ", "/d", version.rawValue, "/f"], environment)
        }
        if let shim = request.steamShim {
            let source = try ContainedFileSystem(root: shim)
            for (name, destination, optional) in [
                ("steam64.exe", "system32/steam.exe", false), ("steam32.exe", "syswow64/steam.exe", false),
                ("lsteamclient64.dll", "system32/lsteamclient.dll", true), ("lsteamclient32.dll", "syswow64/lsteamclient.dll", true)
            ] {
                let input = try SafeRelativePath(name)
                // Our pinned Proton component is steam.exe-only. Older shim
                // sets also contain these DLLs; copy them when supplied.
                if optional { if try source.itemType(at: input) == nil { continue } }
                try copyVerified(source, at: input, into: fs, at: SafeRelativePath("\(path)/drive_c/windows/\(destination)"))
            }
        }
        let bundle = try ContainedFileSystem(root: binary.deletingLastPathComponent().deletingLastPathComponent())
        for name in request.dxmtExtras {
            try copyVerified(bundle, at: SafeRelativePath("lib/wine/x86_64-windows/\(name)"), into: fs,
                at: SafeRelativePath("\(path)/drive_c/windows/system32/\(name)"))
        }
        if request.nvidiaKeys {
            // MIT: yaagl setNVExtension (Copyright (c) 2023 3Shain).
            for key in ["HKLM\\SOFTWARE\\NVIDIA Corporation\\Global", "HKLM\\SYSTEM\\ControlSet001\\Services\\nvlddmkm"] {
                try await run(binary, ["reg", "add", key, "/v", "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}", "/t", "REG_BINARY", "/d", "1", "/f"], environment)
            }
            try await run(binary, ["reg", "add", "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore", "/v", "FullPath", "/t", "REG_SZ", "/d", "C:\\Windows\\System32", "/f"], environment)
        }
        if request.crypt32Native {
            // The pinned yaagl wrapper removes WINEDLLOVERRIDES. Persist the
            // same policy in this game/bundle's prefix, not in the runtime.
            try await run(binary, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "crypt32", "/t", "REG_SZ", "/d", "native,builtin", "/f"], environment)
        }
        let frameRate = try await applyStarRailFrameRate(request, binary: binary, environment: environment)
        // reg.exe success only acknowledges wineserver's in-memory state. Wait
        // for the server to save it, then flush the files and directory before
        // the marker's full-sync boundary can certify this provisioning revision.
        let wineserver = binary.deletingLastPathComponent().appendingPathComponent("wineserver")
        let persisted = try await runner.run(wineserver, arguments: ["-w"], environment: environment,
            currentDirectory: nil, timeout: registryWaitTimeout, timeoutWait: timeoutWait)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard persisted.exitCode == 0 else {
            throw LauncherError.processFailed(executable: wineserver.path, exitCode: persisted.exitCode,
                stderrTail: String(decoding: persisted.stderr.suffix(4096), as: UTF8.self))
        }
        try PrefixShellFolders.validate(in: prefixFS)
        try PrefixShellFolders.requireIdle(prefix: prefix, prefixFS: prefixFS, wineBinary: binary, runtimeRoot: paths.runtimes, inspector: inspector, serverProbe: serverProbe)
        try PrefixShellFolders.repair(in: prefixFS)
        for name in ["system.reg", "user.reg", "userdef.reg"] {
            let registry = try SafeRelativePath("\(path)/\(name)")
            if try fs.itemType(at: registry) != nil { try fs.synchronizeFile(at: registry, durable: false) }
        }
        try fs.synchronizeParentDirectory(of: markerPath)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if needsProvisioning {
            marker.provisioningRevision = Self.provisioningRevision
            try PrefixManager.writeMarker(marker, fs: fs, to: markerPath, pending: SafeRelativePath("\(path)/.macgacha-prefix.pending"))
        }
        return PreparationOutcome(starRailFrameRate: frameRate)
    }

    private func applyStarRailFrameRate(_ request: PreparationRequest, binary: URL,
        environment: [String: String]) async throws -> StarRailFrameRateOutcome? {
        guard let mode = request.starRailFrameRate else { return nil }
        let key = StarRailFrameRate.registryKey(for: request.starRailRegion)
        do {
            let query = try await runner.run(binary, arguments: ["reg", "query", key], environment: environment,
                currentDirectory: nil, timeout: .seconds(10), timeoutWait: timeoutWait)
            try Task.checkCancellation()
            let diagnostic = String(decoding: query.stdout + query.stderr, as: UTF8.self).lowercased()
            guard query.exitCode == 0 else {
                return query.exitCode == 1 && (diagnostic.contains("unable to find the specified registry") ||
                    diagnostic.contains("the system was unable to find the specified registry key or value")) ? .missing : .unreadable
            }
            guard query.stdout.count <= StarRailFrameRate.maximumPayloadBytes * 2 else { return .unreadable }
            let values = StarRailFrameRate.parseQuery(String(decoding: query.stdout, as: UTF8.self))
            guard !values.isEmpty else { return .missing }
            var applied = false, unreadable = false
            for value in values {
                guard let payload = StarRailFrameRate.decodeHex(value.hex), let oldFPS = StarRailFrameRate.currentFPS(payload) else {
                    unreadable = true; continue
                }
                let fps = mode == .unlock120 ? 120 : 60
                if oldFPS == Double(fps) || (mode == .restore && oldFPS != 120) { continue }
                guard let rewritten = StarRailFrameRate.rewrite(payload, fps: fps) else { unreadable = true; continue }
                let result = try await runner.run(binary, arguments: ["reg", "add", key, "/v", value.name,
                    "/t", "REG_BINARY", "/d", StarRailFrameRate.encodeHex(rewritten), "/f"], environment: environment,
                    currentDirectory: nil, timeout: .seconds(10), timeoutWait: timeoutWait)
                try Task.checkCancellation()
                if result.exitCode == 0 { applied = true } else { unreadable = true }
            }
            return unreadable ? .unreadable : applied ? .applied : .unchanged
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? LauncherError) == .cancelled { throw LauncherError.cancelled }
            return .unreadable
        }
    }

    private func run(_ binary: URL, _ arguments: [String], _ environment: [String: String], allowMissingValue: Bool = false) async throws {
        let result = try await runner.run(binary, arguments: arguments, environment: environment, currentDirectory: nil)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if result.exitCode == 0 { return }
        // Wine reg.exe reports an absent value as exit 1. Force the C locale so
        // missing-value diagnostics are stable; access and other failures throw.
        let diagnostic = String(decoding: result.stdout + result.stderr, as: UTF8.self).lowercased()
        if allowMissingValue && result.exitCode == 1 &&
            (diagnostic.contains("unable to find the specified registry value") || diagnostic.contains("unable to find the specified registry key") || diagnostic.contains("the system was unable to find the specified registry key or value")) { return }
        throw LauncherError.processFailed(executable: binary.path, exitCode: result.exitCode,
            stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
    }

    private func fingerprint(_ fs: ContainedFileSystem, at path: SafeRelativePath) throws -> (size: Int64, digest: Digest) {
        guard let size = try fs.size(at: path) else { throw LauncherError.io("Launch preparation file is missing") }
        var hash = StreamingHasher(.sha256), count: Int64 = 0
        try fs.readFile(at: path) { bytes in count += Int64(bytes.count); hash.update(bytes) }
        guard count == size else { throw LauncherError.io("Launch preparation source changed") }
        return (size, hash.finalize())
    }

    private func copyVerified(_ source: ContainedFileSystem, at input: SafeRelativePath, into fs: ContainedFileSystem, at output: SafeRelativePath) throws {
        let expected = try fingerprint(source, at: input)
        let parent = output.components.dropLast().joined(separator: "/")
        let temporary = try SafeRelativePath("\(parent)/.macgacha-prepare-\(UUID().uuidString)")
        defer { try? fs.removeFile(at: temporary) }
        _ = try source.copyRegularFile(at: input, to: temporary, in: fs, maxBytes: expected.size)
        let actual = try fingerprint(fs, at: temporary)
        guard actual.size == expected.size, actual.digest == expected.digest else { throw LauncherError.io("Launch preparation copy mismatch") }
        try fs.fullSync(at: temporary)
        try fs.rename(from: temporary, to: output)
        let published = try fingerprint(fs, at: output)
        guard published.size == expected.size, published.digest == expected.digest else { throw LauncherError.io("Launch preparation publication mismatch") }
    }
}

/// Result of reconciling the ZZZ native-proxy per-app overrides.
public struct NativeProxyOverrideOutcome: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Nothing was written: OFF without ownership, or ON with both values already ours.
        case unchanged
        /// ON: ownership is recorded and both values are present.
        case applied
        /// OFF: our values are gone, durably flushed, and ownership is cleared.
        case removed
    }
    public let action: Action
    /// Keys this experiment created that were kept because they were not provably empty or
    /// could not be proven ours. Foreign values are never deleted to remove a key.
    public let residualKeys: [String]
}

// MARK: - ZZZ native-proxy per-app DLL overrides

/// Owns exactly `HKCU\Software\Wine\AppDefaults\ZenlessZoneZero.exe\DllOverrides` values
/// `d3d11` and `d3dcompiler_47` = `native,builtin` for the Global ZZZ prefix named by its marker.
///
/// Allowed residue after OFF: `AppDefaults` itself (never deleted, even if reg created it), and
/// the app/DllOverrides keys when another actor added values or subkeys to them. The app and
/// DllOverrides keys are removed only when recorded as absent before ON and queried empty now.
extension LaunchPreparation {
    private static let appKey = "HKCU\\Software\\Wine\\AppDefaults\\" + NativeProxyOverrideOwnership.target
    private static let overridesKey = appKey + "\\DllOverrides"

    @discardableResult public func reconcileNativeProxyOverrides(prefix: URL, wineBinary: URL, enabled: Bool) async throws -> NativeProxyOverrideOutcome {
        do {
            return try await BlockingIO.run { try await reconcileNativeProxyOnIO(prefix: prefix, wineBinary: wineBinary, enabled: enabled) }
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func reconcileNativeProxyOnIO(prefix: URL, wineBinary: URL, enabled: Bool) async throws -> NativeProxyOverrideOutcome {
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        let path = try RuntimeJSONFile.relativePath(prefix, root: paths.root)
        guard path.components.count == 2, path.components.first == "Prefixes" else { throw LauncherError.unsafePath(prefix.path) }
        _ = try SafeIdentifier(path.components[1])
        _ = try fs.directoryURL(at: path)
        let lock = try await PrefixManager.acquireLock(fs: fs, prefix: path)
        defer { withExtendedLifetime(lock) {} }
        let markerPath = try SafeRelativePath("\(path)/.macgacha-prefix.json")
        let pendingPath = try SafeRelativePath("\(path)/.macgacha-prefix.pending")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var marker = try decoder.decode(PrefixMarker.self, from: fs.readFile(at: markerPath, maxBytes: PrefixManager.markerLimit))
        // Without ownership there is nothing of ours to remove and OFF must stay inert.
        if !enabled && marker.nativeProxyOverrides == nil { return NativeProxyOverrideOutcome(action: .unchanged, residualKeys: []) }
        // The marker, not the directory name, establishes Global ZZZ. Legacy markers carry no game.
        guard marker.game == NativeProxyOverrideOwnership.game, path.components[1] == "\(NativeProxyOverrideOwnership.game)-\(marker.backend)" else {
            throw LauncherError.io("Native proxy overrides require the Global Zenless Zone Zero prefix")
        }
        try marker.nativeProxyOverrides?.validate()
        let binary = wineBinary.standardizedFileURL
        let sourceRoot = binary.deletingLastPathComponent()
        let sourceFS = try ContainedFileSystem(root: sourceRoot)
        let sourcePath = try RuntimeJSONFile.relativePath(binary, root: sourceRoot)
        let binaryIdentity = try fingerprint(sourceFS, at: sourcePath).digest
        guard marker.schemaVersion == PrefixMarker.schema, marker.state == .ready,
              marker.createdAt.timeIntervalSince1970.isFinite, marker.wineBinaryPath == binary.path,
              marker.wineBinaryIdentity == binaryIdentity else {
            throw LauncherError.io("Native proxy overrides require a ready prefix for this Wine binary")
        }
        guard let prefixFS = try fs.pinDirectoryIfPresent(at: path) else { throw LauncherError.io("Prefix is missing") }
        try PrefixShellFolders.validate(in: prefixFS)
        try PrefixShellFolders.requireIdle(prefix: prefix, prefixFS: prefixFS, wineBinary: binary, runtimeRoot: paths.runtimes, inspector: inspector, serverProbe: serverProbe)
        let environment = PrefixManager.preparationEnvironment(prefix: prefix)

        var outcome = NativeProxyOverrideOutcome(action: .unchanged, residualKeys: [])
        if enabled {
            // Fresh ON: every value must be unowned-absent before ownership is claimed.
            let before = try await queryRegistryKey(Self.overridesKey, binary: binary, environment: environment)
            if marker.nativeProxyOverrides == nil {
                if let listing = before.listing, !Self.overrideValues(in: listing).isEmpty {
                    throw LauncherError.io("Native proxy override conflict: a DLL override already exists and is not owned by this app")
                }
                let appKeyMissing = before.listing == nil
                    ? try await queryRegistryKey(Self.appKey, binary: binary, environment: environment).listing == nil : false
                let record = NativeProxyOverrideOwnership.record(createdAppKey: appKeyMissing, createdOverridesKey: before.listing == nil)
                // Ownership is durable before any reg add, so an interruption stays cleanable.
                marker.nativeProxyOverrides = record
                try PrefixManager.writeMarker(marker, fs: fs, to: markerPath, pending: pendingPath)
            }
            var pending: [String] = []
            let current = before.listing.map(Self.overrideValues) ?? [:]
            for name in NativeProxyOverrideOwnership.valueNames {
                guard let value = current[name] else { pending.append(name); continue }
                // An owned value that someone else changed is a conflict, never adopted or overwritten.
                guard value.type == "REG_SZ", value.data == NativeProxyOverrideOwnership.overrideText else {
                    throw LauncherError.io("Native proxy override conflict: an owned DLL override was changed")
                }
            }
            for name in pending {
                try await runRegistry(binary, ["reg", "add", Self.overridesKey, "/v", name, "/t", "REG_SZ", "/d", NativeProxyOverrideOwnership.overrideText, "/f"], environment)
            }
            if !pending.isEmpty {
                let after = try await queryRegistryKey(Self.overridesKey, binary: binary, environment: environment)
                let values = after.listing.map(Self.overrideValues) ?? [:]
                for name in NativeProxyOverrideOwnership.valueNames {
                    guard let value = values[name], value.type == "REG_SZ", value.data == NativeProxyOverrideOwnership.overrideText else {
                        throw LauncherError.io("Native proxy override value was not stored")
                    }
                }
                outcome = NativeProxyOverrideOutcome(action: .applied, residualKeys: [])
            }
            try await persistRegistry(binary: binary, environment: environment, fs: fs, path: path, prefix: prefix, prefixFS: prefixFS, markerPath: markerPath)
            return outcome
        }

        guard let owned = marker.nativeProxyOverrides else { return outcome }
        let before = try await queryRegistryKey(Self.overridesKey, binary: binary, environment: environment)
        let current = before.listing.map(Self.overrideValues) ?? [:]
        var deletions: [String] = []
        for name in NativeProxyOverrideOwnership.valueNames {
            guard let value = current[name] else { continue }
            // A changed value belongs to someone else now: keep it and keep ownership recorded.
            guard value.type == "REG_SZ", value.data == owned.values[name] else {
                throw LauncherError.io("Native proxy override conflict: an owned DLL override was changed")
            }
            deletions.append(name)
        }
        for name in deletions {
            try await runRegistry(binary, ["reg", "delete", Self.overridesKey, "/v", name, "/f"], environment, allowMissingValue: true)
        }
        var residue: [String] = []
        // Keys are removed only when recorded as ours and queried empty (no values, no subkeys).
        // The prefix is idle under our lock, so nothing can populate them between query and delete.
        var overridesGone = false
        if owned.createdOverridesKey {
            overridesGone = try await removeKeyIfEmpty(Self.overridesKey, binary: binary, environment: environment)
            if !overridesGone { residue.append(Self.overridesKey) }
        }
        if owned.createdAppKey {
            let appGone = overridesGone ? try await removeKeyIfEmpty(Self.appKey, binary: binary, environment: environment) : false
            if !appGone { residue.append(Self.appKey) }
        }
        try await persistRegistry(binary: binary, environment: environment, fs: fs, path: path, prefix: prefix, prefixFS: prefixFS, markerPath: markerPath)
        marker.nativeProxyOverrides = nil
        try PrefixManager.writeMarker(marker, fs: fs, to: markerPath, pending: pendingPath)
        return NativeProxyOverrideOutcome(action: .removed, residualKeys: residue)
    }

    /// Deletes `key` only when it exists and lists no values or subkeys. Returns whether it is now absent.
    private func removeKeyIfEmpty(_ key: String, binary: URL, environment: [String: String]) async throws -> Bool {
        guard let listing = try await queryRegistryKey(key, binary: binary, environment: environment).listing else { return true }
        guard listing.values.isEmpty, listing.subkeyCount == 0 else { return false }
        try await runRegistry(binary, ["reg", "delete", key, "/f"], environment, allowMissingValue: true)
        return true
    }

    /// reg.exe success only acknowledges wineserver's memory. Join the selected server, then
    /// flush the registry files and directory before any ownership change is published.
    private func persistRegistry(binary: URL, environment: [String: String], fs: ContainedFileSystem, path: SafeRelativePath,
        prefix: URL, prefixFS: ContainedFileSystem, markerPath: SafeRelativePath) async throws {
        let wineserver = binary.deletingLastPathComponent().appendingPathComponent("wineserver")
        let persisted = try await runner.run(wineserver, arguments: ["-w"], environment: environment,
            currentDirectory: nil, timeout: registryWaitTimeout, timeoutWait: timeoutWait)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard persisted.exitCode == 0 else {
            throw LauncherError.processFailed(executable: wineserver.path, exitCode: persisted.exitCode,
                stderrTail: String(decoding: persisted.stderr.suffix(4096), as: UTF8.self))
        }
        try PrefixShellFolders.validate(in: prefixFS)
        try PrefixShellFolders.requireIdle(prefix: prefix, prefixFS: prefixFS, wineBinary: binary, runtimeRoot: paths.runtimes, inspector: inspector, serverProbe: serverProbe)
        for name in ["system.reg", "user.reg", "userdef.reg"] {
            let registry = try SafeRelativePath("\(path)/\(name)")
            if try fs.itemType(at: registry) != nil { try fs.synchronizeFile(at: registry, durable: false) }
        }
        try fs.synchronizeParentDirectory(of: markerPath)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
    }

    private func runRegistry(_ binary: URL, _ arguments: [String], _ environment: [String: String], allowMissingValue: Bool = false) async throws {
        let result = try await runner.run(binary, arguments: arguments, environment: environment, currentDirectory: nil,
            timeout: .seconds(10), timeoutWait: timeoutWait)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if result.exitCode == 0 || (allowMissingValue && Self.isMissingDiagnostic(result)) { return }
        throw LauncherError.processFailed(executable: binary.path, exitCode: result.exitCode,
            stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
    }

    /// Absence is only exit 1 with Wine's English diagnostic; every other failure is an error, never "missing".
    ///
    /// Wine's reg.exe prints the queried key's header line only when the key holds a value, so an
    /// existing key with no values prints just the CRLF-separated names of its subkeys, and a key with
    /// neither prints a bare blank line (exit 0). A bare blank line alone is not evidence that the key
    /// exists, so it is confirmed with `reg query KEY /ve`, which always prints the exact header.
    private func queryRegistryKey(_ key: String, binary: URL, environment: [String: String]) async throws -> RegistryKeyQuery {
        let result = try await runner.run(binary, arguments: ["reg", "query", key], environment: environment, currentDirectory: nil,
            timeout: .seconds(10), timeoutWait: timeoutWait)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if result.exitCode == 0 {
            let listing = try Self.decodeListing(result, key: key)
            if listing.values.isEmpty, listing.subkeyCount == 0 {
                try await confirmKeyExists(key, binary: binary, environment: environment)
            }
            return RegistryKeyQuery(listing: listing)
        }
        if Self.isMissingDiagnostic(result) { return RegistryKeyQuery(listing: nil) }
        throw LauncherError.processFailed(executable: binary.path, exitCode: result.exitCode,
            stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
    }

    private static func decodeListing(_ result: ProcessResult, key: String) throws -> RegistryKeyListing {
        guard result.stdout.count <= 65_536, let text = String(data: result.stdout, encoding: .utf8),
              let listing = parseKeyListing(text, expectedKey: key) else {
            throw LauncherError.io("Native proxy override registry query was unreadable")
        }
        return listing
    }

    /// `/ve` lists only the default value, and Wine prints the key header (with the exact key) for any
    /// existing key. Anything but that header plus one unset default is unreadable, never "empty".
    private func confirmKeyExists(_ key: String, binary: URL, environment: [String: String]) async throws {
        let result = try await runner.run(binary, arguments: ["reg", "query", key, "/ve"], environment: environment, currentDirectory: nil,
            timeout: .seconds(10), timeoutWait: timeoutWait)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard result.exitCode == 0 else {
            if Self.isMissingDiagnostic(result) { throw LauncherError.io("Native proxy override registry key vanished during query") }
            throw LauncherError.processFailed(executable: binary.path, exitCode: result.exitCode,
                stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
        }
        let listing = try Self.decodeListing(result, key: key)
        guard listing.subkeyCount == 0, listing.values.count == 1, let unset = listing.values.first,
              unset.name == "(Default)", unset.type == "REG_SZ", unset.data == "(value not set)" else {
            throw LauncherError.io("Native proxy override registry query was unreadable")
        }
    }

    private static func isMissingDiagnostic(_ result: ProcessResult) -> Bool {
        let diagnostic = String(decoding: result.stdout + result.stderr, as: UTF8.self).lowercased()
        return result.exitCode == 1 && (diagnostic.contains("unable to find the specified registry value") || diagnostic.contains("unable to find the specified registry key") ||
            diagnostic.contains("the system was unable to find the specified registry key or value"))
    }

    /// Present values only (names are case-insensitive in the registry), keyed by our canonical names.
    private static func overrideValues(in listing: RegistryKeyListing) -> [String: RegistryValue] {
        var found: [String: RegistryValue] = [:]
        for name in NativeProxyOverrideOwnership.valueNames {
            if let value = listing.values.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { found[name] = value }
        }
        return found
    }

    /// Parses `reg query KEY` output. Wine prints, in order: an optional header naming the queried key
    /// (only when it has values), `    name    REG_x    data` value lines, then one column-0 line per
    /// direct subkey. No lines at all is an empty (or unproven) key: the caller must confirm existence.
    /// Anything else is unreadable (fail closed).
    static func parseKeyListing(_ text: String, expectedKey: String) -> RegistryKeyListing? {
        guard let expected = registryKeyComponents(expectedKey) else { return nil }
        var sawHeader = false, values: [RegistryValue] = []
        var children = Set<[String]>()
        // Character.isNewline also splits "\r\n", which Swift treats as one Character.
        for line in text.split(whereSeparator: \.isNewline) {
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) { continue }
            if line.hasPrefix("    ") {
                guard sawHeader, children.isEmpty, let value = parseValueLine(line.dropFirst(4)) else { return nil }
                values.append(value)
            } else {
                guard let key = registryKeyComponents(String(line)) else { return nil }
                if key == expected {
                    guard !sawHeader, children.isEmpty else { return nil }
                    sawHeader = true
                } else {
                    guard key.count == expected.count + 1, Array(key.dropLast()) == expected,
                          children.insert(key).inserted else { return nil }
                }
            }
        }
        return RegistryKeyListing(values: values, subkeyCount: children.count)
    }

    private static func registryKeyComponents(_ key: String) -> [String]? {
        var parts = key.split(separator: "\\", omittingEmptySubsequences: false).map { $0.lowercased() }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        switch parts[0] {
        case "hkcu", "hkey_current_user": parts[0] = "hkey_current_user"
        default: return nil
        }
        return parts
    }

    private static func parseValueLine(_ line: Substring) -> RegistryValue? {
        guard let marker = line.range(of: "    REG_") else { return nil }
        let name = line[..<marker.lowerBound]
        guard !name.isEmpty else { return nil }
        let rest = line[line.index(marker.lowerBound, offsetBy: 4)...]
        let type: Substring, data: Substring
        if let split = rest.range(of: "    ") { type = rest[..<split.lowerBound]; data = rest[split.upperBound...] }
        else { type = rest; data = "" }
        guard type.count > 4, type.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }) else { return nil }
        return RegistryValue(name: String(name), type: String(type), data: String(data))
    }
}

struct RegistryValue: Equatable, Sendable { let name: String, type: String, data: String }
struct RegistryKeyListing: Equatable, Sendable { let values: [RegistryValue]; let subkeyCount: Int }
struct RegistryKeyQuery: Sendable { let listing: RegistryKeyListing? }
