// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public struct ManagedMod: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let fileCount: Int

    public init(id: String, name: String, enabled: Bool, fileCount: Int) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.fileCount = fileCount
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
