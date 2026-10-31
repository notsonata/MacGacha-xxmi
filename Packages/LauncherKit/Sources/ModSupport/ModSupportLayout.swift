// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

enum ModSupportConstants {
    static let gameID = "starrail"
    static let runtimeBundleID = "d3dmetal-wine11.20-gptk4.0b3"
    static let runnerTarget = "StarRail.exe"
    static let maximumStateBytes = 1 << 20
    static let maximumSettingsTextBytes = 64 << 10
    static let maximumModFiles = 50_000
    static let maximumModBytes: Int64 = 2 << 30
    static let maximumModDepth = 64
}

struct ModSupportLayout: Sendable {
    let root: URL
    let xxmiRoot: URL
    let versions: URL
    let gameRoot: URL
    let modsDirectory: URL
    let packages: URL
    let sessions: URL
    let staging: URL

    init(paths: AppPaths) {
        root = paths.root
        xxmiRoot = paths.root.appendingPathComponent("XXMI", isDirectory: true)
        versions = xxmiRoot.appendingPathComponent("Versions", isDirectory: true)
        gameRoot = xxmiRoot.appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(ModSupportConstants.gameID, isDirectory: true)
        modsDirectory = gameRoot.appendingPathComponent("Mods", isDirectory: true)
        packages = gameRoot.appendingPathComponent("Packages", isDirectory: true)
        sessions = xxmiRoot.appendingPathComponent("Sessions", isDirectory: true)
        staging = xxmiRoot.appendingPathComponent(".staging", isDirectory: true)
    }

    func ensureDirectories(_ fs: ContainedFileSystem, includeMods: Bool = true) throws {
        var paths = ["XXMI", "XXMI/Versions", "XXMI/Games/starrail/Packages", "XXMI/Sessions",
            "XXMI/.staging"]
        if includeMods { paths.append("XXMI/Games/starrail/Mods") }
        for path in paths {
            try fs.createDirectory(at: SafeRelativePath(path))
        }
    }

    /// The managed default library, or the exact folder the user selected.
    func libraryDirectory(for state: ModSupportState) -> URL {
        guard let custom = state.modsDirectory else { return modsDirectory }
        return URL(fileURLWithPath: custom, isDirectory: true)
    }

    var statePath: SafeRelativePath { try! SafeRelativePath("XXMI/Games/starrail/state.json") }

    func packagePath(for version: String) -> SafeRelativePath {
        try! SafeRelativePath("XXMI/Versions/\(version)")
    }

    func manifestPath(for version: String) -> SafeRelativePath {
        try! SafeRelativePath("XXMI/Games/starrail/Packages/\(version).json")
    }

    func sessionPath(_ name: String) -> SafeRelativePath {
        try! SafeRelativePath("XXMI/Sessions/\(name)")
    }

    func stagingPath(_ name: String) -> SafeRelativePath {
        try! SafeRelativePath("XXMI/.staging/\(name)")
    }
}

struct ModSupportState: Codable, Sendable, Equatable {
    struct Mod: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var enabled: Bool
        var fileCount: Int
    }

    var schemaVersion = 1
    var activeVersion: String?
    var injectionEnabled = false
    var riskAcknowledged = false
    var mods: [Mod] = []
    /// An absolute custom library folder. Older state without this key keeps
    /// using the managed default under the app data root.
    var modsDirectory: String?

    func validate() throws {
        guard schemaVersion == 1 else { throw LauncherError.journalCorrupt("unsupported mod support schema") }
        if let activeVersion { _ = try SafeIdentifier(activeVersion) }
        if let modsDirectory {
            guard modsDirectory.hasPrefix("/"), !modsDirectory.utf8.contains(0),
                !modsDirectory.isEmpty else {
                throw LauncherError.journalCorrupt("mod support library path is invalid")
            }
        }
        guard mods.count <= 10_000 else { throw LauncherError.journalCorrupt("mod support state is too large") }
        var ids: Set<String> = []
        var names: Set<String> = []
        for mod in mods {
            _ = try SafeIdentifier(mod.id)
            guard mod.fileCount > 0, mod.fileCount <= ModSupportConstants.maximumModFiles,
                validateDisplayName(mod.name) != nil,
                ids.insert(mod.id).inserted,
                names.insert(foldedName(mod.name)).inserted else {
                throw LauncherError.journalCorrupt("mod support state has an invalid mod")
            }
        }
    }

    func snapshot(installedVersion: String?, modsDirectory: URL? = nil) -> ModSupportSnapshot {
        ModSupportSnapshot(installedVersion: installedVersion, injectionEnabled: injectionEnabled,
            riskAcknowledged: riskAcknowledged,
            mods: mods.map { ManagedMod(id: $0.id, name: $0.name, enabled: $0.enabled, fileCount: $0.fileCount) }
                .sorted {
                    let left = $0.name.lowercased(), right = $1.name.lowercased()
                    return left == right ? $0.id < $1.id : left < right
                },
            modsDirectory: modsDirectory)
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
