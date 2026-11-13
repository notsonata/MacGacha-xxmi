// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Counts from rescanning the library for folders placed there outside the app.
public struct ModLibraryRefreshResult: Sendable, Equatable {
    public let added: Int
    public let removed: Int
    public let updated: Int
    /// Folder names that were left untouched because they are not safe mods.
    public let rejected: [String]
    public let changed: Bool

    public init(added: Int, removed: Int, updated: Int, rejected: [String], changed: Bool) {
        self.added = added; self.removed = removed; self.updated = updated
        self.rejected = rejected; self.changed = changed
    }
}

/// Result of copying SRMI's persistent user file out of a finished launch.
public enum ModUserSettingsOutcome: Sendable, Equatable {
    case stored
    case unchanged
    case superseded
    case notPrepared
    /// The session directory is already gone: an earlier finish harvested and
    /// reclaimed it, so repeating finish after a failed checkpoint is safe.
    case alreadyFinished
}

/// Result of reclaiming launch sessions no journal, live session or recovery
/// still references.
public struct ModSessionSweepReport: Sendable, Equatable {
    public let reclaimed: Int
    public let failed: Int
    public init(reclaimed: Int, failed: Int) { self.reclaimed = reclaimed; self.failed = failed }
}

/// Result of publishing the enabled library into a running launch session.
public struct ModLiveApplyResult: Sendable, Equatable {
    public let enabledMods: Int
    public init(enabledMods: Int) { self.enabledMods = enabledMods }
}

public struct ManagedMod: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let fileCount: Int
    public let folderPath: String

    public init(id: String, name: String, enabled: Bool, fileCount: Int, folderPath: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.fileCount = fileCount
        self.folderPath = folderPath ?? id
    }
}

public struct ModSupportSnapshot: Sendable, Equatable {
    public let installedVersion: String?
    public let injectionEnabled: Bool
    public let riskAcknowledged: Bool
    public let mods: [ManagedMod]
    /// The library the store currently reads. It can be a custom location the
    /// user picked, including one whose volume is temporarily unavailable.
    public let modsDirectory: URL?

    public var isInstalled: Bool { installedVersion != nil }

    public init(installedVersion: String?, injectionEnabled: Bool, riskAcknowledged: Bool, mods: [ManagedMod],
        modsDirectory: URL? = nil) {
        self.installedVersion = installedVersion
        self.injectionEnabled = injectionEnabled
        self.riskAcknowledged = riskAcknowledged
        self.mods = mods
        self.modsDirectory = modsDirectory
    }
}

/// Immutable paths for one launch. Everything the hook needs is inside the
/// session directory, so package updates and mod edits cannot mutate it.
public struct PreparedModLaunch: Sendable, Equatable {
    public let runnerURL: URL
    public let injectorURL: URL
    public let payloadURL: URL
    public let sessionDirectory: URL

    public init(runnerURL: URL, injectorURL: URL, payloadURL: URL, sessionDirectory: URL) {
        self.runnerURL = runnerURL
        self.injectorURL = injectorURL
        self.payloadURL = payloadURL
        self.sessionDirectory = sessionDirectory
    }
}
