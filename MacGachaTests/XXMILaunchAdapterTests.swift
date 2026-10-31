// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import ModSupport
@testable import MacGacha

@Suite struct XXMILaunchAdapterTests {
    @Test func otherGamesNeverConsultHSRInjectionState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ModSupportStore(paths: AppPaths(root: root))
        let adapter = ModSupportLaunchAdapter(store: store)
        let config = try await adapter.prepare(gameID: "genshin", runtimeBundleID: "unrelated",
            backendD3D11: root.appendingPathComponent("does-not-exist"))
        #expect(config == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
