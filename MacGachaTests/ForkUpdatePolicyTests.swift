// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
@testable import MacGacha

@MainActor @Suite struct ForkUpdatePolicyTests {
    private var valid: [String: Any] {
        ["MacGachaForkUpdatesEnabled": true,
         "SUFeedURL": "https://github.com/notsonata/MacGacha-xxmi/releases/latest/download/appcast.xml",
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
    }
    @Test func requiresExplicitForkProvisioning() {
        #expect(SparkleUpdaterService.permitsForkUpdates(info: valid))
        var info = valid
        info["MacGachaForkUpdatesEnabled"] = false
        #expect(!SparkleUpdaterService.permitsForkUpdates(info: info))
        info = valid; info["SUFeedURL"] = "https://github.com/deruta74/MacGacha/releases/latest/download/appcast.xml"
        #expect(!SparkleUpdaterService.permitsForkUpdates(info: info))
        info = valid; info["SUPublicEDKey"] = "twDFIWAvlw1lBPC12GhgVqHMvPTpgYCUstqhuVJ/vPg="
        #expect(!SparkleUpdaterService.permitsForkUpdates(info: info))
        info = valid; info["SUPublicEDKey"] = "not-a-key"
        #expect(!SparkleUpdaterService.permitsForkUpdates(info: info))
    }
}
