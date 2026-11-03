import Foundation

struct ReleaseVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct ReleaseAsset: Decodable, Equatable {
    let name: String
    let browser_download_url: URL
}
struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [ReleaseAsset]
    let draft: Bool?
    let prerelease: Bool?
}
enum UpdatePlan {
    static func asset(for version: ReleaseVersion, in assets: [ReleaseAsset]) -> ReleaseAsset? {
        assets.first { $0.name == "Holler-\(version).zip" } ?? assets.first { $0.name.hasSuffix(".zip") }
    }
    static func newerVersion(_ release: GitHubRelease, than current: ReleaseVersion) -> ReleaseVersion? {
        guard release.draft != true, release.prerelease != true,
              let version = ReleaseVersion(release.tag_name), version > current else { return nil }
        return version
    }
}
