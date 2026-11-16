// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

enum ModSupportConstants {
    static let runtimeBundleID = "d3dmetal-wine11.20-gptk4.0b3"
    /// The running app's CFBundleVersion, compared with a package's minimumAppBuild.
    static let runningAppBuild: Int? = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) }
    static let maximumStateBytes = 1 << 20
    static let maximumSettingsTextBytes = 64 << 10
    static let maximumSRMIUserConfigBytes = 1 << 20
    static let maximumSRMIUserConfigEncodedBytes = 2 << 20
    static let maximumModFiles = 50_000
    static let maximumModBytes: Int64 = 2 << 30
    static let maximumModDepth = 64
}

struct ModSupportLayout: Sendable {
    let root: URL
    let profile: ModSupportProfile
    let xxmiRoot: URL
    let versions: URL
    let gameRoot: URL
    let modsDirectory: URL
    let packages: URL
    let sessions: URL
    let staging: URL
    private let versionsPath: String
    private let gamePath: String
    private let sessionsPath: String
    private let stagingRootPath: String

    init(paths: AppPaths, profile: ModSupportProfile = .starRail) {
        root = paths.root
        self.profile = profile
        xxmiRoot = paths.root.appendingPathComponent("XXMI", isDirectory: true)
        versionsPath = Self.versionsPath(for: profile)
        gamePath = "XXMI/Games/\(profile.gameID)"
        sessionsPath = Self.sessionsPath(for: profile)
        stagingRootPath = Self.stagingRootPath(for: profile)
        versions = paths.root.appendingPathComponent(versionsPath, isDirectory: true)
        gameRoot = paths.root.appendingPathComponent(gamePath, isDirectory: true)
        modsDirectory = gameRoot.appendingPathComponent("Mods", isDirectory: true)
        packages = gameRoot.appendingPathComponent("Packages", isDirectory: true)
        sessions = paths.root.appendingPathComponent(sessionsPath, isDirectory: true)
        staging = paths.root.appendingPathComponent(stagingRootPath, isDirectory: true)
    }

    private static func versionsPath(for profile: ModSupportProfile) -> String {
        profile == .starRail ? "XXMI/Versions" : "XXMI/Versions/\(profile.gameID)"
    }

    private static func sessionsPath(for profile: ModSupportProfile) -> String {
        profile == .starRail ? "XXMI/Sessions" : "XXMI/Sessions/\(profile.gameID)"
    }

    private static func stagingRootPath(for profile: ModSupportProfile) -> String {
        profile == .starRail ? "XXMI/.staging" : "XXMI/.staging/\(profile.gameID)"
    }

    func ensureDirectories(_ fs: ContainedFileSystem, includeMods: Bool = true) throws {
        var paths = ["XXMI", "XXMI/Versions", versionsPath, "\(gamePath)/Packages",
            "\(gamePath)/User", "XXMI/Sessions", sessionsPath, "XXMI/.staging", stagingRootPath]
        if includeMods { paths.append("\(gamePath)/Mods") }
        for path in paths {
            try fs.createDirectory(at: SafeRelativePath(path))
        }
    }

    /// The managed default library, or the exact folder the user selected.
    func libraryDirectory(for state: ModSupportState) -> URL {
        guard let custom = state.modsDirectory else { return modsDirectory }
        return URL(fileURLWithPath: custom, isDirectory: true)
    }

    var statePath: SafeRelativePath { try! SafeRelativePath("\(gamePath)/state.json") }
    var userDirectoryPath: SafeRelativePath { try! SafeRelativePath("\(gamePath)/User") }
    var userConfigPath: SafeRelativePath { try! SafeRelativePath("\(gamePath)/User/d3dx-user.json") }

    func packagePath(for version: String) -> SafeRelativePath {
        try! SafeRelativePath("\(versionsPath)/\(version)")
    }

    func manifestPath(for version: String) -> SafeRelativePath {
        try! SafeRelativePath("\(gamePath)/Packages/\(version).json")
    }

    func sessionPath(_ name: String) -> SafeRelativePath {
        try! SafeRelativePath("\(sessionsPath)/\(name)")
    }

    var sessionsRootPath: SafeRelativePath { try! SafeRelativePath(sessionsPath) }
    var stagingRootRelativePath: SafeRelativePath { try! SafeRelativePath(stagingRootPath) }

    func stagingPath(_ name: String) -> SafeRelativePath {
        try! SafeRelativePath("\(stagingRootPath)/\(name)")
    }

    func sessionMarkerPath(_ name: String) -> SafeRelativePath {
        try! SafeRelativePath("\(sessionsPath)/\(name)/.macgacha-session.json")
    }
}

struct ModSupportState: Codable, Sendable, Equatable {
    struct Mod: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var enabled: Bool
        var fileCount: Int
        /// The folder inside the library. Imported mods use their stable ID;
        /// folders added in Finder keep their own name so a rescan does not
        /// rename or copy user data.
        var folder: String?

        var folderPath: String { folder ?? id }
    }

    var schemaVersion = 1
    var activeVersion: String?
    var injectionEnabled = false
    var riskAcknowledged = false
    var mods: [Mod] = []
    /// An absolute custom library folder. Older state without this key keeps
    /// using the managed default under the app data root.
    var modsDirectory: String?
    /// Library folders the user removed from MacGacha but kept on disk. Refresh
    /// never adopts them again. nil decodes older state and is never written.
    var ignoredFolders: [String]?

    func isIgnored(_ folder: String) -> Bool {
        ignoredFolders?.contains { foldedName($0) == foldedName(folder) } ?? false
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw LauncherError.journalCorrupt("unsupported mod support schema") }
        if let activeVersion { _ = try SafeIdentifier(activeVersion) }
        if let modsDirectory {
            guard modsDirectory.hasPrefix("/"), !modsDirectory.utf8.contains(0),
                !modsDirectory.isEmpty else {
                throw LauncherError.journalCorrupt("mod support library path is invalid")
            }
        }
        guard mods.count <= 10_000, (ignoredFolders?.count ?? 0) <= 10_000 else {
            throw LauncherError.journalCorrupt("mod support state is too large")
        }
        var ignored: Set<String> = []
        for folder in ignoredFolders ?? [] {
            guard let path = try? SafeRelativePath(folder), path.components.count == 1, path.description == folder,
                validateDisplayName(folder) == folder, ignored.insert(foldedName(folder)).inserted else {
                throw LauncherError.journalCorrupt("mod support state has an invalid ignored folder")
            }
        }
        var ids: Set<String> = []
        var names: Set<String> = []
        var folders: Set<String> = []
        for mod in mods {
            _ = try SafeIdentifier(mod.id)
            let folder = mod.folderPath
            guard let folderPath = try? SafeRelativePath(folder), folderPath.components.count == 1,
                folderPath.description == folder, validateDisplayName(folder) == folder else {
                throw LauncherError.journalCorrupt("mod support state has an invalid mod folder")
            }
            guard mod.fileCount > 0, mod.fileCount <= ModSupportConstants.maximumModFiles,
                validateDisplayName(mod.name) != nil,
                ids.insert(mod.id).inserted,
                names.insert(foldedName(mod.name)).inserted,
                folders.insert(foldedName(folder)).inserted, !ignored.contains(foldedName(folder)) else {
                throw LauncherError.journalCorrupt("mod support state has an invalid mod")
            }
        }
    }

    func snapshot(installedVersion: String?, modsDirectory: URL? = nil, addedDates: [String: Date] = [:]) -> ModSupportSnapshot {
        ModSupportSnapshot(installedVersion: installedVersion, injectionEnabled: injectionEnabled,
            riskAcknowledged: riskAcknowledged,
            mods: mods.map { ManagedMod(id: $0.id, name: $0.name, enabled: $0.enabled, fileCount: $0.fileCount,
                folderPath: $0.folderPath, addedAt: addedDates[$0.id]) }
                .sorted {
                    let left = $0.name.lowercased(), right = $1.name.lowercased()
                    return left == right ? $0.id < $1.id : left < right
                },
            modsDirectory: modsDirectory, ignoredFolders: (ignoredFolders ?? []).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending })
    }
}

func validateDisplayName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 200, trimmed != ".", trimmed != "..",
        !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 47 || $0.value == 92 }) else {
        return nil
    }
    return trimmed
}

func foldedName(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
}

func stableModID(for name: String) -> String {
    var slug = ""
    var separatorPending = false
    for scalar in name.lowercased().unicodeScalars {
        let value = scalar.value
        let allowed = (48...57).contains(value) || (97...122).contains(value)
        if allowed {
            if separatorPending && !slug.isEmpty { slug.append("-") }
            separatorPending = false
            slug.unicodeScalars.append(scalar)
        } else if value == 95 || value == 45 {
            separatorPending = !slug.isEmpty
        } else {
            separatorPending = !slug.isEmpty
        }
    }
    if slug.isEmpty { slug = "mod" }
    if slug.utf8.count > 48 { slug = String(slug.prefix(48)) }
    var hasher = StreamingHasher(.sha256)
    hasher.update(Data(name.utf8))
    return "\(slug)-\(hasher.finalize().hex.prefix(12))"
}
