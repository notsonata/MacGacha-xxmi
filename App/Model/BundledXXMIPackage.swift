// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport

/// The offline compatibility package shipped inside the app. Only the known
/// archive name is accepted, so a stray resource can never be installed.
struct BundledXXMIPackage: Sendable, Equatable {
    static let packageID = "hsr-srmi"
    static let manifestName = "manifest.json"
    static let archiveName = "hsr-srmi.zip"

    let manifest: ModPackageManifest
    let archiveURL: URL

    init(manifest: ModPackageManifest, archiveURL: URL) {
        self.manifest = manifest
        self.archiveURL = archiveURL
    }

    static func load(bundle: Bundle = .main) async throws -> BundledXXMIPackage {
        let manifestURL = bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "XXMI")
            ?? bundle.url(forResource: "manifest", withExtension: "json")
        let archiveURL = bundle.url(forResource: "hsr-srmi", withExtension: "zip", subdirectory: "XXMI")
            ?? bundle.url(forResource: "hsr-srmi", withExtension: "zip")
        guard let manifestURL, let archiveURL else {
            throw LauncherError.io("The bundled XXMI package is missing")
        }
        return try await load(manifestURL: manifestURL, archiveURL: archiveURL)
    }

    /// Explicit package import: a folder containing the same sidecar manifest
    /// and archive names as the built-in package.
    static func load(directory: URL) async throws -> BundledXXMIPackage {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw LauncherError.io("The selected XXMI package must be a local folder")
        }
        return try await load(manifestURL: directory.appendingPathComponent(manifestName),
            archiveURL: directory.appendingPathComponent(archiveName))
    }

    private static func load(manifestURL: URL, archiveURL: URL) async throws -> BundledXXMIPackage {
        guard archiveURL.lastPathComponent == archiveName else {
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
        guard manifest.id == packageID else {
            throw LauncherError.io("The selected package is not XXMI for Honkai: Star Rail")
        }
        return BundledXXMIPackage(manifest: manifest, archiveURL: archiveURL)
    }
}
