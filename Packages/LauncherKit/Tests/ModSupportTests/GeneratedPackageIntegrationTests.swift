// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import ModSupport

private var generatedPackage: URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("App/Resources/XXMI")
}

@Suite struct GeneratedPackageIntegrationTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: generatedPackage.appendingPathComponent("manifest.json").path)))
    func actualBundledManifestDecodesAndPackageInstalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try JSONDecoder().decode(ModPackageManifest.self,
            from: Data(contentsOf: generatedPackage.appendingPathComponent("manifest.json")))
        let store = ModSupportStore(paths: AppPaths(root: root))
        try await store.install(manifest: manifest, archive: generatedPackage.appendingPathComponent("hsr-srmi.zip"))
        let snapshot = try await store.snapshot()
        #expect(snapshot.installedVersion == manifest.version)
        #expect(!snapshot.injectionEnabled)
    }
}
