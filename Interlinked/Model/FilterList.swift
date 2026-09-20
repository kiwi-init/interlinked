import Foundation

/// Host rules read from Adblock Plus filter lists such as EasyList. The blocker
/// works on hosts only, so path, cosmetic, and resource-type rules are skipped:
/// applying a narrower rule to a whole host would break pages.
struct FilterRules: Equatable, Codable {
    var blocked: Set<String> = []
    var blockedThirdParty: Set<String> = []
    var allowed: Set<String> = []

    var isEmpty: Bool { blocked.isEmpty && blockedThirdParty.isEmpty }
    var count: Int { blocked.count + blockedThirdParty.count }

    mutating func merge(_ other: FilterRules) {
        blocked.formUnion(other.blocked)
        blockedThirdParty.formUnion(other.blockedThirdParty)
        allowed.formUnion(other.allowed)
    }

    static func parse(_ text: String) -> FilterRules {
        var rules = FilterRules()
        text.enumerateLines { line, _ in rules.add(line) }
        // A host blocked everywhere needs no separate third-party entry.
        rules.blockedThirdParty.subtract(rules.blocked)
        return rules
    }

    private mutating func add(_ rawLine: String) {
        var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["),
              !line.contains("##"), !line.contains("#@#"), !line.contains("#?#") else { return }
        let exception = line.hasPrefix("@@")
        if exception { line = line.dropFirst(2) }
        guard line.hasPrefix("||") else { return }
        line = line.dropFirst(2)

        var options: Substring = ""
        if let dollar = line.lastIndex(of: "$") {
            options = line[line.index(after: dollar)...]
            line = line[..<dollar]
        }
        guard line.hasSuffix("^") else { return }
        let host = line.dropLast().lowercased()
        guard Self.isHost(host) else { return }

        var thirdParty = false
        for option in options.split(separator: ",") {
            switch option {
            case "third-party", "3p": thirdParty = true
            case "important", "all": break
            default: return
            }
        }
        if exception {
            // A third-party-only exception would need context the matcher lacks.
            if !thirdParty { allowed.insert(host) }
        } else if thirdParty {
            blockedThirdParty.insert(host)
        } else {
            blocked.insert(host)
        }
    }

    private static func isHost(_ value: String) -> Bool {
        guard value.contains("."), !value.hasPrefix("."), !value.hasSuffix("."), value.count <= 253 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
        }
    }
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
