import Foundation

/// major.minor.patch, for "is the published release newer than me" checks.
public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "1.2.3", "v1.2.3", "1.2" (patch 0), "1.2.3-beta" (pre-release ignored); nil for anything else.
    /// Surrounding whitespace is tolerated (a version read from a file ends in a newline).
    public init?(_ string: String) {
        var core = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if core.hasPrefix("v") {
            core = core.dropFirst()
        }
        // Pre-release ("-beta.1") and build metadata ("+sha") don't order releases here.
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            core = core[..<cut]
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count == 3 ? numbers[2] : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
