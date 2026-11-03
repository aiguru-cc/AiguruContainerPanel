import Foundation

struct CLIVersion: Codable, Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ string: String) {
        let match = string.firstMatch(of: /\d+\.\d+(?:\.\d+)?/).map { String($0.output) } ?? "0.0.0"
        let parts = match.split(separator: ".").compactMap { Int($0) }
        major = parts.indices.contains(0) ? parts[0] : 0
        minor = parts.indices.contains(1) ? parts[1] : 0
        patch = parts.indices.contains(2) ? parts[2] : 0
    }

    init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    static let unknown = CLIVersion(major: 0, minor: 0)
    var isKnown: Bool { self != .unknown }
    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
