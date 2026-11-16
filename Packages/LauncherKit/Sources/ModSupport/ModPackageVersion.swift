// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

/// Release order of compatibility package versions such as `2.4.3-macgacha.4`:
/// the upstream version first, then the fork's package revision. Anything else
/// (for example a diagnostic build) has no known order, so the app never offers
/// it as an update or treats replacing it as an upgrade.
public struct ModPackageVersion: Comparable, Sendable {
    let upstream: [Int]
    let revision: Int

    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].hasPrefix("macgacha."),
            let revision = Int(parts[1].dropFirst("macgacha.".count)), revision >= 0 else { return nil }
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...4).contains(numbers.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        upstream = numbers.compactMap { $0 }
        self.revision = revision
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.upstream.count, rhs.upstream.count)
        for index in 0..<count {
            let left = index < lhs.upstream.count ? lhs.upstream[index] : 0
            let right = index < rhs.upstream.count ? rhs.upstream[index] : 0
            if left != right { return left < right }
        }
        return lhs.revision < rhs.revision
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// How the package bundled with this app relates to the installed one.
public enum ModPackageRelation: Sendable, Equatable {
    case notInstalled, noBundledPackage, same, bundledNewer, bundledOlder, unknownOrder

    public static func between(installed: String?, bundled: String?) -> Self {
        guard let installed else { return .notInstalled }
        guard let bundled else { return .noBundledPackage }
        if installed == bundled { return .same }
        guard let old = ModPackageVersion(installed), let new = ModPackageVersion(bundled) else { return .unknownOrder }
        if new == old { return .unknownOrder }
        return new > old ? .bundledNewer : .bundledOlder
    }
}
