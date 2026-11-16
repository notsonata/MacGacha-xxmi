// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary
import RuntimeManager

/// App-owned preparation for an opt-in compatibility injection. Returning nil
/// keeps the launch byte-for-byte identical to a normal launch.
public protocol LaunchInjectionPreparing: Sendable {
    /// Read-only eligibility check before journal creation or prefix preparation.
    func validateEligibility(game: GameDefinition, settings: LaunchSettings) async throws
    func prepare(gameID: String, runtimeBundleID: String, backendD3D11: URL) async throws -> LaunchInjectionConfiguration?
    /// Settings-aware preparation lets providers fail closed for a game whose
    /// current launch settings cannot be injected, before any snapshot exists.
    func prepare(game: GameDefinition, runtimeBundleID: String, backendD3D11: URL,
        settings: LaunchSettings) async throws -> LaunchInjectionConfiguration?
    /// Runs once supervision has verified the session ended. Providers may
    /// harvest runtime-written state; failures retain recovery ownership for retry.
    func finish(configuration: LaunchInjectionConfiguration) async throws
    /// Removes a snapshot that was prepared but never ran because the launch
    /// failed before its journal recorded it. Best effort; the startup sweep
    /// reclaims anything left behind.
    func discard(configuration: LaunchInjectionConfiguration) async
    /// Reclaims one game's snapshots that no journal, live or recovery session
    /// references. The manager holds that game's session lock for the call.
    func sweepSessions(gameID: String, retaining: [URL]) async
    /// Explicit, user-requested publication of the current enabled mods into a
    /// running session's snapshot. The manager has verified the session is the
    /// journal's active, running, unended one and serializes it with end.
    func applyLive(configuration: LaunchInjectionConfiguration) async throws
}

public extension LaunchInjectionPreparing {
    func validateEligibility(game: GameDefinition, settings: LaunchSettings) async throws {}
    func prepare(game: GameDefinition, runtimeBundleID: String, backendD3D11: URL,
        settings: LaunchSettings) async throws -> LaunchInjectionConfiguration? {
        try await prepare(gameID: game.id, runtimeBundleID: runtimeBundleID, backendD3D11: backendD3D11)
    }
    func finish(configuration: LaunchInjectionConfiguration) async throws {}
    func discard(configuration: LaunchInjectionConfiguration) async {}
    func sweepSessions(gameID: String, retaining: [URL]) async {}
    func applyLive(configuration: LaunchInjectionConfiguration) async throws {
        throw LauncherError.io("Live mod updates are unavailable")
    }
}

/// Immutable per-launch snapshot produced by the mod-support store. The files
/// are copied before spawn so later library changes cannot alter a live game.
public struct LaunchInjectionConfiguration: Codable, Equatable, Sendable {
    public let runnerURL: URL
    public let injectorURL: URL
    public let payloadURL: URL
    public let sessionDirectory: URL
    /// Game/profile identity recorded with the snapshot so recovery never
    /// applies one game's injection context to another. Older journals omit it.
    public let gameID: String?
    public let targetExecutable: String?
    /// How the snapshot reaches the game. Older journals omit it and always
    /// used the hook runner; nil is never encoded, so their bytes are unchanged.
    public let loading: ModLoadingMode?

    public var resolvedGameID: String { gameID ?? "starrail" }
    public var resolvedTargetExecutable: String { targetExecutable ?? "StarRail.exe" }
    public var resolvedLoading: ModLoadingMode { loading ?? .hookRunner }

    /// Drive letter (without colon) that maps the profile's sessions folder in
    /// the game prefix. Snapshot INI paths and helper arguments use it.
    public static let sessionDriveLetter = "M"

    public init(runnerURL: URL, injectorURL: URL, payloadURL: URL, sessionDirectory: URL,
        gameID: String? = nil, targetExecutable: String? = nil, loading: ModLoadingMode? = nil) {
        self.runnerURL = runnerURL; self.injectorURL = injectorURL; self.payloadURL = payloadURL
        self.sessionDirectory = sessionDirectory; self.gameID = gameID
        self.targetExecutable = targetExecutable
        self.loading = loading
    }

    func validateForJournal() throws {
        for url in [runnerURL, injectorURL, payloadURL, sessionDirectory] {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
                url.host == nil || url.host == "" || url.host == "localhost" else {
                throw LauncherError.journalCorrupt("Invalid injection snapshot path")
            }
        }
        if let gameID { _ = try SafeIdentifier(gameID) }
        guard ["StarRail.exe", "ZenlessZoneZero.exe"].contains(resolvedTargetExecutable) else {
            throw LauncherError.journalCorrupt("Invalid injection target executable")
        }
        // Native loading is established only for Global ZZZ. Legacy hook-runner
        // records (including older ZZZ ones) keep their existing validation.
        if resolvedLoading == .nativeProxy {
            guard gameID == "zzz", targetExecutable == "ZenlessZoneZero.exe" else {
                throw LauncherError.journalCorrupt("Invalid native injection identity")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runnerURL, injectorURL, payloadURL, sessionDirectory, gameID, targetExecutable, loading
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runnerURL = try container.decode(URL.self, forKey: .runnerURL)
        injectorURL = try container.decode(URL.self, forKey: .injectorURL)
        payloadURL = try container.decode(URL.self, forKey: .payloadURL)
        sessionDirectory = try container.decode(URL.self, forKey: .sessionDirectory)
        gameID = try container.decodeIfPresent(String.self, forKey: .gameID)
        targetExecutable = try container.decodeIfPresent(String.self, forKey: .targetExecutable)
        loading = try container.decodeIfPresent(ModLoadingMode.self, forKey: .loading)
    }
}

/// The only compatibility pair established against a live HSR session.
enum LaunchInjection {
    static let runtimeBundleID = "d3dmetal-wine11.20-gptk4.0b3"
    private static let supportedFamilies: Set<GameFamily> = [.starrail, .zzz]
    private static let backendD3D11Path = "lib/wine/x86_64-windows/d3d11.dll"

    static func backendD3D11URL(for bundle: InstalledRuntimeBundle) -> URL {
        bundle.root.appendingPathComponent(backendD3D11Path)
    }

    static func supports(game: GameDefinition, bundle: InstalledRuntimeBundle, settings: LaunchSettings) -> Bool {
        guard game.region == .global, supportedFamilies.contains(game.family),
            bundle.id.rawValue == runtimeBundleID, settings.backend == .d3dmetal else { return false }
        // ZZZ's default renderer is DirectX 12. Injection is only established
        // for D3D11, so an enabled configuration must fail closed instead of
        // changing the user's launch settings.
        return game.family != .zzz || !settings.directX12
    }

    /// Editions whose snapshots can exist at all, independent of settings.
    static func mayInject(_ game: GameDefinition) -> Bool {
        game.region == .global && supportedFamilies.contains(game.family)
    }

    static func targetExecutable(for family: GameFamily) -> String {
        family == .zzz ? "ZenlessZoneZero.exe" : "StarRail.exe"
    }

    struct Prepared: Sendable {
        let configuration: LaunchInjectionConfiguration
        let windowsRunnerPath: String
        let windowsInjectorPath: String
        let windowsPayloadPath: String

        var loading: ModLoadingMode { configuration.resolvedLoading }

        /// The helper starts the original resolved guest command inside the same
        /// Wine host. Keeping the resolved Wine executable, environment, working
        /// directory and component copies preserves the normal launch contract.
        func wrap(_ launch: ResolvedLaunch, expectedGamePath: String) throws -> ResolvedLaunch {
            try Self.checkTarget(launch, expectedGamePath: expectedGamePath)
            // A native snapshot is never started through the helper: that would
            // silently change its loading route. Its caller must place the
            // payload and use `nativeLaunch` instead.
            guard loading == .hookRunner else {
                throw LauncherError.io("This mod snapshot uses native loading and cannot start through the hook runner")
            }
            var arguments = [windowsRunnerPath, "--loader", windowsInjectorPath, "--payload", windowsPayloadPath]
            // The runner keeps StarRail.exe as its default target; ZZZ must be
            // explicit so the helper never verifies or injects the wrong image.
            if configuration.resolvedTargetExecutable != "StarRail.exe" {
                arguments.append(contentsOf: ["--target-exe", configuration.resolvedTargetExecutable])
            }
            arguments.append("--")
            arguments.append(contentsOf: launch.arguments)
            return ResolvedLaunch(executable: launch.executable, arguments: arguments, environment: launch.environment,
                currentDirectory: launch.currentDirectory, hidden: launch.hidden, copyIfPresent: launch.copyIfPresent,
                blockedHosts: launch.blockedHosts, preparation: launch.preparation,
                requiredComponents: launch.requiredComponents, componentCopies: launch.componentCopies,
                displayFallback: launch.displayFallback, fpsInjector: launch.fpsInjector)
        }

        /// Native loading keeps the resolved command byte-for-byte unchanged. The
        /// caller places the verified payload before spawning it.
        func nativeLaunch(_ launch: ResolvedLaunch, expectedGamePath: String) throws -> ResolvedLaunch {
            try Self.checkTarget(launch, expectedGamePath: expectedGamePath)
            guard loading == .nativeProxy else {
                throw LauncherError.io("This mod snapshot requires the hook runner")
            }
            return launch
        }

        private static func checkTarget(_ launch: ResolvedLaunch, expectedGamePath: String) throws {
            guard launch.arguments.contains(expectedGamePath) else {
                throw LauncherError.io("The resolved launch command is not the expected game executable")
            }
        }
    }

    /// Blocking I/O; the launch manager calls this through `BlockingIO.run`.
    static func validate(_ configuration: LaunchInjectionConfiguration, paths: AppPaths, prefix: URL,
        bundle: InstalledRuntimeBundle, game: GameDefinition? = nil) throws -> Prepared {
        try configuration.validateForJournal()
        if let game {
            guard configuration.resolvedGameID == game.id,
                configuration.resolvedTargetExecutable == targetExecutable(for: game.family) else {
                throw LauncherError.io("The injection snapshot does not match this game")
            }
        }
        let sessionDirectory = configuration.sessionDirectory.standardizedFileURL
        let sessionComponents = try relativeComponents(of: sessionDirectory, under: paths.root)
        guard sessionComponents.count >= 3, Array(sessionComponents.prefix(2)) == ["XXMI", "Sessions"] else {
            throw LauncherError.unsafePath(sessionDirectory.path)
        }
        let fs = try ContainedFileSystem(root: paths.root).pinRoot()
        let sessionPath = try SafeRelativePath(sessionComponents.joined(separator: "/"))
        guard try fs.itemType(at: sessionPath) == .directory else {
            throw LauncherError.io("The injection snapshot directory is missing")
        }
        let runner = try regularFile(configuration.runnerURL.standardizedFileURL, in: sessionDirectory,
            sessionComponents: sessionComponents, fs: fs)
        let injector = try regularFile(configuration.injectorURL.standardizedFileURL, in: sessionDirectory,
            sessionComponents: sessionComponents, fs: fs)
        let payload = try regularFile(configuration.payloadURL.standardizedFileURL, in: sessionDirectory,
            sessionComponents: sessionComponents, fs: fs)
        if configuration.resolvedLoading == .nativeProxy {
            try verifyNativePayload(configuration, payload: payload, sessionDirectory: sessionDirectory,
                sessionComponents: sessionComponents, fs: fs)
        }
        try verifyBackend(bundle: bundle, paths: paths)
        try verifyRootDrive(paths: paths, prefix: prefix)
        let sessionsRoot = sessionDirectory.deletingLastPathComponent().standardizedFileURL
        try mapSessionDrive(paths: paths, prefix: prefix, sessionsRoot: sessionsRoot)
        return Prepared(configuration: LaunchInjectionConfiguration(runnerURL: runner, injectorURL: injector,
            payloadURL: payload, sessionDirectory: sessionDirectory, gameID: configuration.gameID,
            targetExecutable: configuration.targetExecutable, loading: configuration.loading),
            windowsRunnerPath: try sessionDrivePath(for: runner, sessionsRoot: sessionsRoot),
            windowsInjectorPath: try sessionDrivePath(for: injector, sessionsRoot: sessionsRoot),
            windowsPayloadPath: try sessionDrivePath(for: payload, sessionsRoot: sessionsRoot))
    }

    /// Drive letter that maps the profile's sessions folder inside the game
    /// prefix. 3DMigoto builds every mod path from the payload's own location,
    /// and Windows path buffers are limited to 260 characters, so
    /// `M:\<session>\payload\Mods\…` leaves about 64 more characters for each mod
    /// than the full `Z:\Users\…\Application Support\MacGacha\XXMI\Sessions\…` path.
    package static let sessionDrive = LaunchInjectionConfiguration.sessionDriveLetter.lowercased() + ":"

    /// The game-visible path of a snapshot file through the session drive.
    package static func sessionDrivePath(for url: URL, sessionsRoot: URL) throws -> String {
        let components = try relativeComponents(of: url.standardizedFileURL, under: sessionsRoot)
        return LaunchInjectionConfiguration.sessionDriveLetter + ":\\" + components.joined(separator: "\\")
    }

    /// Creates or verifies `dosdevices/m:` in the selected prefix. A mapping that
    /// already points at this sessions folder is kept; MacGacha's own stale
    /// mapping (another sessions folder under its data root) is replaced; any
    /// other existing M: mapping fails closed instead of being overwritten.
    private static func mapSessionDrive(paths: AppPaths, prefix: URL, sessionsRoot: URL) throws {
        let prefixComponents = try relativeComponents(of: prefix.standardizedFileURL, under: paths.root)
        let fs = try ContainedFileSystem(root: paths.root).pinRoot()
        let dosdevicesPath = try SafeRelativePath((prefixComponents + ["dosdevices"]).joined(separator: "/"))
        guard try fs.itemType(at: dosdevicesPath) == .directory else {
            throw LauncherError.io("The selected prefix has no drive mappings")
        }
        let dosdevices = prefix.standardizedFileURL.appendingPathComponent("dosdevices", isDirectory: true)
        let link = dosdevices.appendingPathComponent(sessionDrive)
        let expected = sessionsRoot.standardizedFileURL.path
        let manager = FileManager.default
        if let entry = try fs.inspectTree(at: dosdevicesPath).first(where: { $0.path.components == [sessionDrive] }) {
            guard entry.type == .other, let target = entry.linkTarget else {
                throw LauncherError.io("Drive M: in the game prefix is used by something else; remove it to use mods")
            }
            let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : URL(fileURLWithPath: target, relativeTo: dosdevices)).standardizedFileURL
            if resolved.path == expected { return }
            let ownSessions = paths.root.standardizedFileURL.appendingPathComponent("XXMI/Sessions", isDirectory: true).path
            guard resolved.path == ownSessions || resolved.path.hasPrefix(ownSessions + "/") else {
                throw LauncherError.io("Drive M: in the game prefix already points to another folder; remove it to use mods")
            }
            try manager.removeItem(at: link)
        }
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: expected)
    }

    /// Files the game loads natively from the session payload. Everything must
    /// be a real file or directory inside this game's own canonical session;
    /// symlinks and foreign snapshots fail closed.
    static let nativePayloadFiles = ["d3d11.dll", "d3dcompiler_47.dll", "d3dx.ini", "Core/ZZMI/main.ini"]
    static let nativePayloadDirectories = ["Core", "Core/ZZMI", "Mods"]

    private static func verifyNativePayload(_ configuration: LaunchInjectionConfiguration, payload: URL,
        sessionDirectory: URL, sessionComponents: [String], fs: ContainedFileSystem) throws {
        guard sessionComponents.count == 4, sessionComponents[2] == configuration.resolvedGameID,
            let name = sessionComponents.last, UUID(uuidString: name)?.uuidString == name else {
            throw LauncherError.unsafePath(sessionDirectory.path)
        }
        guard payload.lastPathComponent == "d3d11.dll" else {
            throw LauncherError.io("The native mod payload must be d3d11.dll")
        }
        let payloadComponents = try relativeComponents(of: payload.deletingLastPathComponent().standardizedFileURL,
            under: sessionDirectory)
        let expected: [(String, ContainedFileSystem.ItemType)] = nativePayloadDirectories.map { ($0, .directory) }
            + nativePayloadFiles.map { ($0, .regularFile) }
        for (relative, type) in expected {
            let path = try SafeRelativePath((sessionComponents + payloadComponents
                + relative.split(separator: "/").map(String.init)).joined(separator: "/"))
            // itemType refuses leaf and ancestor symlinks.
            guard try fs.itemType(at: path) == type else {
                throw LauncherError.io("The native mod snapshot is incomplete")
            }
        }
    }

    private static func regularFile(_ url: URL, in sessionDirectory: URL, sessionComponents: [String],
        fs: ContainedFileSystem) throws -> URL {
        let components = try relativeComponents(of: url, under: sessionDirectory)
        let path = try SafeRelativePath((sessionComponents + components).joined(separator: "/"))
        guard try fs.itemType(at: path) == .regularFile else {
            throw LauncherError.io("Injection snapshot files must be regular files")
        }
        return url
    }

    private static func verifyBackend(bundle: InstalledRuntimeBundle, paths: AppPaths) throws {
        let url = backendD3D11URL(for: bundle)
        let components = try relativeComponents(of: url, under: paths.runtimes)
        let fs = try ContainedFileSystem(root: paths.runtimes).pinRoot()
        guard try fs.itemType(at: SafeRelativePath(components.joined(separator: "/"))) == .regularFile else {
            throw LauncherError.io("The verified D3DMetal backend is unavailable")
        }
    }

    /// WinePath emits Z: paths, so the selected prefix must really map Z: to
    /// the filesystem root. Never guess a drive mapping for a snapshot file.
    private static func verifyRootDrive(paths: AppPaths, prefix: URL) throws {
        let prefixComponents = try relativeComponents(of: prefix.standardizedFileURL, under: paths.root)
        let fs = try ContainedFileSystem(root: paths.root).pinRoot()
        let dosdevices = try SafeRelativePath((prefixComponents + ["dosdevices"]).joined(separator: "/"))
        let entries = try fs.inspectTree(at: dosdevices)
        guard let mapping = entries.first(where: { $0.path.components == ["z:"] }),
            mapping.type == .other, let target = mapping.linkTarget else {
            throw LauncherError.io("The selected prefix does not map Z: to the filesystem root")
        }
        let base = prefix.standardizedFileURL.appendingPathComponent("dosdevices", isDirectory: true)
        let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target)
            : URL(fileURLWithPath: target, relativeTo: base)
        guard resolved.standardizedFileURL.path == "/" else {
            throw LauncherError.io("The selected prefix does not map Z: to the filesystem root")
        }
    }

    private static func relativeComponents(of url: URL, under root: URL) throws -> [String] {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
            url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw LauncherError.unsafePath(url.absoluteString) }
        let base = root.standardizedFileURL.path.split(separator: "/").map(String.init)
        let components = url.standardizedFileURL.path.split(separator: "/").map(String.init)
        guard components.count > base.count, Array(components.prefix(base.count)) == base else {
            throw LauncherError.unsafePath(url.path)
        }
        return Array(components.dropFirst(base.count))
    }
}
