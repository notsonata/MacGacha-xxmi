// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// SRMI writes persistent variables (including mod toggle state and hunting
/// settings) beside `d3dx.ini` — `payload/d3dx_user.ini` in our snapshot. The
/// snapshot must stay immutable, so the app seeds it from this durable store and
/// harvests it back only after LaunchManager has verified the session ended.
private struct StoredUserConfig: Codable, Equatable {
    var schemaVersion = 1
    var revision = 0
    var data: Data?

    func validate() throws {
        guard schemaVersion == 1, revision >= 0 else {
            throw LauncherError.journalCorrupt("mod support user settings are invalid")
        }
        guard (data?.count ?? 0) <= ModSupportConstants.maximumSRMIUserConfigBytes else {
            throw LauncherError.journalCorrupt("mod support user settings are too large")
        }
    }
}

private struct SessionUserConfigMarker: Codable, Equatable {
    var schemaVersion = 1
    var baselineRevision = 0
    var payloadDirectory: String?

    func validate() throws {
        guard schemaVersion == 1, baselineRevision >= 0 else {
            throw LauncherError.journalCorrupt("mod support session marker is invalid")
        }
        if let payloadDirectory {
            let path = try SafeRelativePath(payloadDirectory)
            guard path.description == payloadDirectory else {
                throw LauncherError.journalCorrupt("mod support session marker is invalid")
            }
        }
    }
}

extension ModSupportStore {
    private static let userConfigName = "d3dx_user.ini"

    private static func loadStoredUserConfig(layout: ModSupportLayout,
        fs: ContainedFileSystem) throws -> StoredUserConfig {
        guard let type = try fs.itemType(at: layout.userConfigPath) else { return StoredUserConfig() }
        guard type == .regularFile else { throw LauncherError.unsafePath(layout.userConfigPath.description) }
        do {
            let data = try fs.readFile(at: layout.userConfigPath,
                maxBytes: ModSupportConstants.maximumSRMIUserConfigEncodedBytes)
            let stored = try JSONDecoder().decode(StoredUserConfig.self, from: data)
            try stored.validate()
            return stored
        } catch LauncherError.cancelled {
            throw LauncherError.cancelled
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError.journalCorrupt("mod support user settings are invalid")
        }
    }

    private static func saveStoredUserConfig(_ stored: StoredUserConfig, layout: ModSupportLayout,
        fs: ContainedFileSystem) throws {
        try stored.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        guard data.count <= ModSupportConstants.maximumSRMIUserConfigEncodedBytes else {
            throw LauncherError.io("mod support user settings exceed their size limit")
        }
        try fs.createDirectory(at: SafeRelativePath("XXMI/Games/starrail/User"))
        try writeAtomicallyReconciled(data, to: layout.userConfigPath, fs: fs)
    }

    private static func sessionUserConfigPath(_ sessionName: String,
        payloadDirectory: SafeRelativePath?) -> SafeRelativePath {
        let prefix = payloadDirectory.map { $0.description + "/" } ?? ""
        return try! SafeRelativePath("XXMI/Sessions/\(sessionName)/\(prefix)\(userConfigName)")
    }

    /// Adds the durable user file and a baseline marker to a fresh session.
    /// Failing to seed is a launch failure, not a silent loss of preferences.
    static func seedUserConfig(fs: ContainedFileSystem, layout: ModSupportLayout, sessionName: String,
        payloadDirectory: SafeRelativePath?) throws {
        let stored = try loadStoredUserConfig(layout: layout, fs: fs)
        if let data = stored.data {
            let path = sessionUserConfigPath(sessionName, payloadDirectory: payloadDirectory)
            try fs.writeAtomically(data, to: path)
        }
        let marker = SessionUserConfigMarker(baselineRevision: stored.revision,
            payloadDirectory: payloadDirectory?.description)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        guard data.count <= ModSupportConstants.maximumSRMIUserConfigEncodedBytes else {
            throw LauncherError.io("mod support session marker exceeds its size limit")
        }
        try fs.writeAtomically(data, to: layout.sessionMarkerPath(sessionName))
    }

    private static func sessionName(for url: URL, layout: ModSupportLayout) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
            url.host == nil || url.host == "" || url.host == "localhost" else {
            throw LauncherError.unsafePath(url.absoluteString)
        }
        let base = layout.sessions.standardizedFileURL.path
        let directory = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard directory.hasPrefix(prefix) else { throw LauncherError.unsafePath(directory) }
        let name = String(directory.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/") else { throw LauncherError.unsafePath(directory) }
        _ = try SafeIdentifier(name)
        return name
    }

    static func finishLaunch(sessionDirectory: URL, layout: ModSupportLayout,
        fileOps: any FileOps) throws -> ModUserSettingsOutcome {
        let name = try sessionName(for: sessionDirectory, layout: layout)
        let fs = try ContainedFileSystem(root: layout.root, fileOps: fileOps)
        let sessionPath = layout.sessionPath(name)
        guard try fs.itemType(at: sessionPath) == .directory else {
            throw LauncherError.unsafePath(sessionDirectory.path)
        }
        let markerPath = layout.sessionMarkerPath(name)
        guard let markerType = try fs.itemType(at: markerPath) else { return .notPrepared }
        guard markerType == .regularFile else { throw LauncherError.unsafePath(markerPath.description) }
        let marker: SessionUserConfigMarker
        do {
            let data = try fs.readFile(at: markerPath, maxBytes: ModSupportConstants.maximumSRMIUserConfigEncodedBytes)
            marker = try JSONDecoder().decode(SessionUserConfigMarker.self, from: data)
            try marker.validate()
        } catch LauncherError.cancelled {
            throw LauncherError.cancelled
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError.journalCorrupt("mod support session marker is invalid")
        }
        let stored = try loadStoredUserConfig(layout: layout, fs: fs)
        guard stored.revision == marker.baselineRevision else { return .superseded }
        let payload = try marker.payloadDirectory.map { value -> SafeRelativePath in
            let path = try SafeRelativePath(value)
            guard path.description == value else {
                throw LauncherError.journalCorrupt("mod support session marker is invalid")
            }
            return path
        }
        let configPath = sessionUserConfigPath(name, payloadDirectory: payload)
        let data: Data?
        if let type = try fs.itemType(at: configPath) {
            guard type == .regularFile else { throw LauncherError.unsafePath(configPath.description) }
            data = try fs.readFile(at: configPath,
                maxBytes: ModSupportConstants.maximumSRMIUserConfigBytes)
        } else {
            data = nil
        }
        if data == stored.data {
            try? fs.removeFile(at: markerPath)
            return .unchanged
        }
        try saveStoredUserConfig(StoredUserConfig(revision: stored.revision + 1, data: data),
            layout: layout, fs: fs)
        try? fs.removeFile(at: markerPath)
        return .stored
    }
}
