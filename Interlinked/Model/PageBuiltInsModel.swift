import Foundation

/// A filter list in uBlock Origin syntax. Trusted lists may use scriptlets that
/// rewrite network responses, which is how video ads are removed.
struct BlockList: Equatable {
    var name: String
    var url: URL
    var trusted: Bool

    static let standard: [BlockList] = [
        BlockList(name: "uBlock filters", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.min.txt")!, trusted: true),
        BlockList(name: "uBlock filters – Quick fixes", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt")!, trusted: true),
        BlockList(name: "uBlock filters – Privacy", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt")!, trusted: true),
        BlockList(name: "uBlock filters – Unbreak", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.min.txt")!, trusted: true),
        BlockList(name: "uBlock filters – Badware risks", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/badware.min.txt")!, trusted: true),
        BlockList(name: "EasyList", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt")!, trusted: false),
        BlockList(name: "EasyPrivacy", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt")!, trusted: false),
        BlockList(name: "Peter Lowe’s Ad and tracking server list", url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext")!, trusted: false),
    ]
}

enum PageDarkMode: String, CaseIterable, Identifiable {
    case off
    case system
    case always

    static let defaultsKey = "builtins.darkMode"

    var id: Self { self }

    var label: String {
        switch self {
        case .off: "Off"
        case .system: "Match macOS appearance"
        case .always: "Always"
        }
    }
}

/// A site is a host without a leading "www.", so an exemption made on
/// www.example.com also covers example.com.
enum SiteKey {
    static func site(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
