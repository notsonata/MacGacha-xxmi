// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport

/// The offline compatibility package shipped inside the app. Only the known
/// per-game archive name is accepted, so a stray resource can never be installed.
struct BundledXXMIPackage: Sendable, Equatable {
    static let packageID = ModSupportProfile.starRail.packageID
    static let manifestName = "manifest.json"
    static let archiveName = ModSupportProfile.starRail.archiveName
    static let zzzPackageID = ModSupportProfile.zzz.packageID
    static let zzzArchiveName = ModSupportProfile.zzz.archiveName

    let manifest: ModPackageManifest
    let archiveURL: URL

    init(manifest: ModPackageManifest, archiveURL: URL) {
        self.manifest = manifest
        self.archiveURL = archiveURL
    }

    static func load(gameID: String = ModSupportProfile.starRail.gameID,
        bundle: Bundle = .main) async throws -> BundledXXMIPackage {
        guard let profile = ModSupportProfile.find(gameID: gameID) else {
            throw LauncherError.io("The bundled XXMI package is not available for this game")
        }
        let manifestURL = bundle.url(forResource: profile.manifestName, withExtension: nil,
            subdirectory: profile.bundledSubdirectory)
            ?? bundle.url(forResource: profile.manifestName, withExtension: nil)
        let archiveBase = (profile.archiveName as NSString).deletingPathExtension
        let archiveURL = bundle.url(forResource: archiveBase, withExtension: "zip",
            subdirectory: profile.bundledSubdirectory)
            ?? bundle.url(forResource: archiveBase, withExtension: "zip")
        guard let manifestURL, let archiveURL else {
            throw LauncherError.io("The bundled XXMI package is missing")
        }
        return try await load(profile: profile, manifestURL: manifestURL, archiveURL: archiveURL)
    }

    /// Explicit package import: a folder containing the same sidecar manifest
    /// and archive names as the selected game's built-in package.
    static func load(directory: URL, gameID: String = ModSupportProfile.starRail.gameID) async throws
        -> BundledXXMIPackage {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw LauncherError.io("The selected XXMI package must be a local folder")
        }
        guard let profile = ModSupportProfile.find(gameID: gameID) else {
            throw LauncherError.io("The selected package is not available for this game")
        }
        // Explicit imports accept the profile's unique manifest or the plain
        // `manifest.json` name used by packages built before profiles existed.
        let manifestURL = [profile.manifestName, manifestName].first {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }.map { directory.appendingPathComponent($0) }
            ?? directory.appendingPathComponent(profile.manifestName)
        return try await load(manifestURL: manifestURL,
            archiveURL: directory.appendingPathComponent(profile.archiveName), profile: profile)
    }

    private static func load(profile: ModSupportProfile, manifestURL: URL,
        archiveURL: URL) async throws -> BundledXXMIPackage {
        try await load(manifestURL: manifestURL, archiveURL: archiveURL, profile: profile)
    }

    private static func load(manifestURL: URL, archiveURL: URL,
        profile: ModSupportProfile) async throws -> BundledXXMIPackage {
        guard archiveURL.lastPathComponent == profile.archiveName else {
            throw LauncherError.io("The XXMI package archive has an unexpected name")
        }
        let manifest = try await BlockingIO.run {
            let data: Data
            do {
                let fs = try ContainedFileSystem(root: manifestURL.deletingLastPathComponent())
                data = try fs.readFile(at: SafeRelativePath(manifestURL.lastPathComponent), maxBytes: 4 << 20)
            }
            catch { throw LauncherError.io("The XXMI package manifest is missing") }
            do {
                return try JSONDecoder().decode(ModPackageManifest.self, from: data)
            } catch {
                throw LauncherError.io("The XXMI package manifest is invalid")
            }
        }
        guard manifest.id == profile.packageID, manifest.gameID == profile.gameID else {
            throw LauncherError.io("The selected package is not XXMI for this game")
        }
        return BundledXXMIPackage(manifest: manifest, archiveURL: archiveURL)
    }
}
