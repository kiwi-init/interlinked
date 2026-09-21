import Foundation

enum NavigationKind: Sendable {
    case link, form, popup, download, redirect, reload, history, other
}

struct NavigationReview: Equatable, Sendable {
    enum Disposition: Int, Comparable, Sendable {
        case allow, warn, block
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Reason: String, Equatable, Sendable {
        case activeContentURL = "The destination uses an active-content URL that a page must not open as a top-level site."
        case externalScheme = "The destination leaves normal web browsing and uses another URL scheme."
        case embeddedCredentials = "The destination contains a username or password before the hostname."
        case insecureDowngrade = "The navigation changes from an encrypted HTTPS page to HTTP."
        case encodedHostname = "The destination hostname uses encoded international-domain notation."
        case mixedScriptHostname = "The destination hostname mixes writing systems and may be visually misleading."
        case publicIPAddress = "The destination uses a public IP address instead of a hostname."
        case unusualPort = "The destination uses an unusual network port."
        case invalidPort = "The destination uses a port outside the valid network range."
        case crossOriginForm = "This form sends data to a different site."
        case crossOriginPopup = "This popup opens a site different from the page that requested it."
        case crossOriginDownload = "This download comes from a site different from the page that requested it."
        case crossSiteRedirect = "The redirect chain changes to a different site."
        case misleadingLinkText = "The visible link names a different site than its destination."
        case invalidWebDestination = "The destination is not a valid HTTP or HTTPS website."
    }

    var disposition: Disposition
    var sourceOrigin: String?
    var destinationOrigin: String
    var linkText: String?
    var reasons: [Reason]

    var exceptionKey: NavigationExceptionKey? {
        guard disposition == .warn, !reasons.isEmpty,
              destinationOrigin.hasPrefix("http://") || destinationOrigin.hasPrefix("https://") else { return nil }
        return NavigationExceptionKey(origin: destinationOrigin, reasons: reasons.map(\.rawValue).sorted())
    }

    var advisoryEvidence: String {
        var lines = ["Destination origin: \(destinationOrigin)"]
        if let sourceOrigin { lines.append("Source origin: \(sourceOrigin)") }
        if let linkText, !linkText.isEmpty { lines.append("Visible link text: \(String(linkText.prefix(160)))") }
        lines.append("Deterministic warning facts: " + reasons.map(\.rawValue).joined(separator: " "))
        return lines.joined(separator: "\n")
    }
}

enum NavigationSafety {
    static func review(
        destination: URL,
        source: URL?,
        kind: NavigationKind,
        linkText: String? = nil
    ) -> NavigationReview {
        let scheme = destination.scheme?.lowercased() ?? ""
        var disposition: NavigationReview.Disposition = .allow
        var reasons: [NavigationReview.Reason] = []

        func add(_ reason: NavigationReview.Reason, _ level: NavigationReview.Disposition = .warn) {
            if !reasons.contains(reason) { reasons.append(reason) }
            disposition = max(disposition, level)
        }

        if ["javascript", "data"].contains(scheme) {
            add(.activeContentURL, .block)
        } else if scheme == "about", destination.absoluteString == "about:blank" {
            // The browser uses about:blank as its empty page.
        } else if !["http", "https"].contains(scheme) {
            add(.externalScheme)
        } else if destination.host?.isEmpty != false {
            add(.invalidWebDestination, .block)
        }

        if destination.user != nil || destination.password != nil { add(.embeddedCredentials) }

        let sourceScheme = source?.scheme?.lowercased()
        if sourceScheme == "https", scheme == "http" { add(.insecureDowngrade) }

        if let host = destination.host?.lowercased(), !host.isEmpty {
            if host.contains("xn--") { add(.encodedHostname) }
            if mixesWritingSystems(host) { add(.mixedScriptHostname) }
            if isIPAddress(host), !isLocalHost(host) { add(.publicIPAddress) }
            if let port = destination.port {
                if !(1...65_535).contains(port) {
                    add(.invalidPort, .block)
                } else if !isLocalHost(host),
                          !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
                    add(.unusualPort)
                }
            }
        }

        if kind == .form, let source, isWeb(source), isWeb(destination), !sameSite(source, destination) {
            add(.crossOriginForm)
        }

        if kind == .popup, let source, isWeb(source), isWeb(destination), !sameSite(source, destination) {
            add(.crossOriginPopup)
        }

        if kind == .download, let source, isWeb(source), isWeb(destination), !sameSite(source, destination) {
            add(.crossOriginDownload)
        }

        if kind == .redirect, let source, isWeb(source), isWeb(destination), !sameSite(source, destination) {
            add(.crossSiteRedirect)
        }

        if let claimed = claimedHost(in: linkText), let actual = destination.host,
           registrableDomain(claimed) != registrableDomain(actual) {
            add(.misleadingLinkText)
        }

        return NavigationReview(
            disposition: disposition,
            sourceOrigin: source.flatMap(origin),
            destinationOrigin: origin(destination) ?? sanitizedFallback(destination),
            linkText: linkText.map(cleanText),
            reasons: reasons
        )
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var value = "\(scheme)://\(host)"
        if let port = url.port { value += ":\(port)" }
        return value
    }

    static func sameSite(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = lhs.host, let b = rhs.host else { return false }
        return registrableDomain(a) == registrableDomain(b)
    }

    private static func sanitizedFallback(_ url: URL) -> String {
        (url.scheme?.lowercased()).map { $0 + ":" } ?? "Unknown destination"
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let pieces = host.split(separator: ".")
        return pieces.count == 4 && pieces.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }

    static func mixesWritingSystems(_ host: String) -> Bool {
        var latin = false, greek = false, cyrillic = false
        for scalar in host.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x007A, 0x00C0...0x024F: latin = true
            case 0x0370...0x03FF: greek = true
            case 0x0400...0x052F: cyrillic = true
            default: break
            }
        }
        return [latin, greek, cyrillic].filter { $0 }.count > 1
    }

    private static func claimedHost(in text: String?) -> String? {
        guard let text else { return nil }
        let clean = cleanText(text)
        for token in clean.components(separatedBy: .whitespacesAndNewlines) {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'.,;:!?"))
            guard candidate.contains("."), !candidate.contains("@") else { continue }
            let value = candidate.contains("://") ? candidate : "https://" + candidate
            if let host = URLComponents(string: value)?.host, host.contains(".") { return host.lowercased() }
        }
        return nil
    }

    static func registrableDomain(_ host: String) -> String {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        if isIPAddress(value) { return value }
        let labels = value.split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let twoLevelSuffixes: Set<String> = ["co.uk", "org.uk", "com.br", "com.au", "co.jp", "co.nz", "com.mx", "com.sg"]
        let suffix = labels.suffix(2).joined(separator: ".")
        return twoLevelSuffixes.contains(suffix) ? labels.suffix(3).joined(separator: ".") : suffix
    }

    private static func cleanText(_ text: String) -> String {
        text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
