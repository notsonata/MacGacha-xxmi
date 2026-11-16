// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// How a prepared mod snapshot reaches the game. Shared by ModSupport (which
/// prepares the snapshot) and Launch (which journals and starts it) without
/// either module depending on the other.
public enum ModLoadingMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// The established route: the session's helper starts the resolved game
    /// command and loads the payload through the injector.
    case hookRunner
    /// The game loads the session payload's `d3d11.dll` through ordinary
    /// native DLL loading. The resolved game command is spawned unchanged.
    case nativeProxy
}
