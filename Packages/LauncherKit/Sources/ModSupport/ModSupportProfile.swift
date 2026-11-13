// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// One supported game's XXMI identity. Storage, package and launch settings stay
/// separate so installing or enabling one game can never touch another.
public struct ModSupportProfile: Sendable, Hashable {
    public let gameID: String
    public let packageID: String
    public let archiveName: String
    /// The bundled manifest must not collide with another game's `manifest.json`
    /// after Xcode flattens the resources directory.
    public let manifestName: String
    public let runnerTarget: String
    public let bundledSubdirectory: String
    public let suggestedLibraryFolderName: String
    /// The only runtime bundle injection is verified on. A newer recommended
    /// catalog bundle never inherits this authorization.
    public var verifiedRuntimeBundleID: String { ModSupportConstants.runtimeBundleID }
    /// The bundled HSR package predates the stricter id check; imported HSR
    /// packages keep working exactly as before.
    let requiresExactPackageID: Bool

    public static let starRail = ModSupportProfile(gameID: "starrail", packageID: "hsr-srmi",
        archiveName: "hsr-srmi.zip", manifestName: "manifest.json",
        runnerTarget: "StarRail.exe", bundledSubdirectory: "XXMI",
        suggestedLibraryFolderName: "MacGacha-HSR-Mods", requiresExactPackageID: false)
    public static let zzz = ModSupportProfile(gameID: "zzz", packageID: "zzz-zzmi",
        archiveName: "zzz-zzmi.zip", manifestName: "zzz-zzmi.manifest.json",
        runnerTarget: "ZenlessZoneZero.exe", bundledSubdirectory: "XXMI",
        suggestedLibraryFolderName: "MacGacha-ZZZ-Mods", requiresExactPackageID: true)

    public static let all = [starRail, zzz]

    public static func find(gameID: String) -> ModSupportProfile? {
        all.first { $0.gameID == gameID }
    }

    func accepts(packageID: String) -> Bool {
        !requiresExactPackageID || packageID == self.packageID
    }
}
