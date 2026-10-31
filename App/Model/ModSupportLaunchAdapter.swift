// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Launch
import ModSupport

/// Only Global HSR is opted into the compatibility module. Other game launch
/// paths never consult HSR's persisted injection preference.
struct ModSupportLaunchAdapter: LaunchInjectionPreparing {
    let store: ModSupportStore

    func prepare(gameID: String, runtimeBundleID: String, backendD3D11: URL) async throws
        -> LaunchInjectionConfiguration? {
        guard gameID == "starrail" else { return nil }
        guard let snapshot = try await store.prepareLaunch(gameID: gameID,
            runtimeBundleID: runtimeBundleID, backendD3D11: backendD3D11) else { return nil }
        return LaunchInjectionConfiguration(runnerURL: snapshot.runnerURL,
            injectorURL: snapshot.injectorURL, payloadURL: snapshot.payloadURL,
            sessionDirectory: snapshot.sessionDirectory)
    }
}
