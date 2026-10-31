// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import Sparkle

@MainActor @Observable final class SparkleUpdaterService: NSObject, AppUpdating, SPUUpdaterDelegate {
    private(set) var canCheckForUpdates = false
    private var automaticChecks = false
    var isInstallingUpdate: Bool { gate?.isInstallingUpdate ?? false }
    @ObservationIgnored private var gate: UpdateRelaunchGate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(startingUpdater: false,
        updaterDelegate: self, userDriverDelegate: nil)

    var automaticallyChecksForUpdates: Bool {
        get { automaticChecks }
        set {
            guard Self.permitsForkUpdates(info: Bundle.main.infoDictionary ?? [:]) else { return }
            controller.updater.automaticallyChecksForUpdates = newValue; automaticChecks = newValue
        }
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    static func permitsStartup(environment: [String: String], testBundleLoaded: Bool,
        debugBuild: Bool = SparkleUpdaterService.isDebugBuild) -> Bool {
        !debugBuild && !testBundleLoaded && environment["XCTestConfigurationFilePath"] == nil && environment["XCTestBundlePath"] == nil
    }

    /// Fork builds must never fall back to upstream's feed or signing identity.
    static func permitsForkUpdates(info: [String: Any]) -> Bool {
        guard info["MacGachaForkUpdatesEnabled"] as? Bool == true,
            let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
            url.scheme == "https", url.host == "github.com",
            url.path.hasPrefix("/notsonata/MacGacha-xxmi/releases/"),
            let key = info["SUPublicEDKey"] as? String,
            let decoded = Data(base64Encoded: key), decoded.count == 32,
            key != "twDFIWAvlw1lBPC12GhgVqHMvPTpgYCUstqhuVJ/vPg=" else { return false }
        return true
    }

    func start(isBusy: @escaping @MainActor () -> Bool) {
        guard gate == nil, Self.permitsForkUpdates(info: Bundle.main.infoDictionary ?? [:]), Self.permitsStartup(environment: ProcessInfo.processInfo.environment,
            testBundleLoaded: NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil) else { return }
        gate = UpdateRelaunchGate(isBusy: isBusy)
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.canCheckForUpdates = self.controller.updater.canCheckForUpdates
                }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.automaticChecks = self.controller.updater.automaticallyChecksForUpdates
                }
            }
        ]
        controller.startUpdater()
    }

    func checkForUpdates() {
        if canCheckForUpdates && controller.updater.canCheckForUpdates { controller.checkForUpdates(nil) }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        gate?.postponeRelaunch(installHandler) ?? true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { gate?.installationAborted() }
}
