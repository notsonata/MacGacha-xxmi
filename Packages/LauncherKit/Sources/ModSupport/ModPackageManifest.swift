// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public struct ModPackageFile: Codable, Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// The external sidecar contract for a versioned compatibility package. The ZIP
/// contains package files only; this manifest is never stored inside the archive.
public struct ModPackageManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let gameID: String
    public let supportedRuntimeBundleIDs: [String]
    public let runnerPath: String
    public let injectorPath: String
    public let payloadPath: String
    public let archiveSize: Int64
    public let archiveSHA256: String
    public let files: [ModPackageFile]
    public let sources: [String: String]
    public let license: String

    public init(schemaVersion: Int = 1, id: String, version: String, gameID: String,
        supportedRuntimeBundleIDs: [String], runnerPath: String, injectorPath: String, payloadPath: String,
        archiveSize: Int64, archiveSHA256: String, files: [ModPackageFile], sources: [String: String], license: String) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.gameID = gameID
        self.supportedRuntimeBundleIDs = supportedRuntimeBundleIDs
        self.runnerPath = runnerPath
        self.injectorPath = injectorPath
        self.payloadPath = payloadPath
        self.archiveSize = archiveSize
        self.archiveSHA256 = archiveSHA256
        self.files = files
        self.sources = sources
        self.license = license
    }
}

extension ModPackageManifest {
    static let maximumFileCount = 20_000
    static let maximumExpandedBytes: Int64 = 1 << 30
    static let maximumArchiveBytes: Int64 = 1 << 30
    static let maximumEncodedBytes = 8 << 20

    func validate() throws {
        guard schemaVersion == 1 else { throw LauncherError.io("Unsupported mod package schema") }
        _ = try SafeIdentifier(id)
        _ = try SafeIdentifier(version)
        _ = try SafeIdentifier(gameID)
        guard (1...16).contains(supportedRuntimeBundleIDs.count),
            Set(supportedRuntimeBundleIDs).count == supportedRuntimeBundleIDs.count else {
            throw LauncherError.io("Invalid mod package runtime list")
        }
        for runtime in supportedRuntimeBundleIDs { _ = try SafeIdentifier(runtime) }
        guard (0..<Self.maximumArchiveBytes).contains(archiveSize) else {
            throw LauncherError.io("Invalid mod package archive size")
        }
        _ = try Digest(algorithm: .sha256, hex: archiveSHA256)
        guard !license.isEmpty, license.utf8.count <= 4096, !license.unicodeScalars.contains(where: Self.isControl),
            sources.count <= 64 else {
            throw LauncherError.io("Invalid mod package license or sources")
        }
        for (key, value) in sources {
            guard !key.isEmpty, !value.isEmpty, key.utf8.count <= 4096, value.utf8.count <= 4096,
                !key.unicodeScalars.contains(where: Self.isControl), !value.unicodeScalars.contains(where: Self.isControl) else {
                throw LauncherError.io("Invalid mod package source pin")
            }
        }
        guard (1...Self.maximumFileCount).contains(files.count) else {
            throw LauncherError.io("Invalid mod package file list")
        }
        var byPath: [String: ModPackageFile] = [:]
        var folded: Set<String> = []
        var total: Int64 = 0
        for file in files {
            let path = try SafeRelativePath(file.path)
            guard path.description == file.path, file.size >= 0,
                (file.sha256.utf8.count == 64) else {
                throw LauncherError.io("Invalid mod package file entry")
            }
            _ = try Digest(algorithm: .sha256, hex: file.sha256)
            guard byPath.updateValue(file, forKey: file.path) == nil,
                folded.insert(Self.foldedPath(file.path)).inserted else {
                throw LauncherError.io("Duplicate mod package file path")
            }
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow, sum <= Self.maximumExpandedBytes else {
                throw LauncherError.fileTooLarge(path: "mod package", limit: Int(Self.maximumExpandedBytes))
            }
            total = sum
        }
        let runner = try SafeRelativePath(runnerPath)
        let injector = try SafeRelativePath(injectorPath)
        let payload = try SafeRelativePath(payloadPath)
        guard runner.description == runnerPath, injector.description == injectorPath,
            payload.description == payloadPath, runner != injector, runner != payload, injector != payload,
            byPath[runnerPath] != nil, byPath[injectorPath] != nil, byPath[payloadPath] != nil else {
            throw LauncherError.io("Invalid mod package entry paths")
        }
    }

    private static func foldedPath(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 32 || scalar.value == 127
    }
}
