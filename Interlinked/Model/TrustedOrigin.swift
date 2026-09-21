import Foundation

/// Browser-controlled site identity. Page titles, favicons, and AI labels never
/// replace this value.
struct TrustedOrigin: Equatable, Sendable {
    enum Transport: String, Equatable, Sendable {
        case https
        case http
        case other

        var isSecure: Bool { self == .https }
        var compactLabel: String {
            switch self {
            case .https: return "HTTPS"
            case .http: return "Not Secure"
            case .other: return "Connection"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .https: return "HTTPS"
            case .http: return "not secure HTTP"
            case .other: return "non-web connection"
            }
        }
    }

    var url: URL
    var scheme: String
    var host: String
    var asciiHost: String
    var registrableDomain: String
    var transport: Transport
    var mixedScript: Bool

    var isRemote: Bool { transport == .http || transport == .https }
    var usesPunycode: Bool { asciiHost.localizedCaseInsensitiveCompare(host) != .orderedSame || asciiHost.contains("xn--") }
    var displayHost: String { usesPunycode ? asciiHost : registrableDomain }
    var compactLabel: String {
        transport == .http ? "Not Secure \(displayHost)" : displayHost
    }
    var accessibilityLabel: String {
        "\(transport.accessibilityLabel), \(displayHost)"
    }
    var fullURL: String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.user = nil
        parts.password = nil
        if usesPunycode { parts.percentEncodedHost = asciiHost }
        return parts.string ?? url.absoluteString
    }
    var connectionDetail: String {
        var lines = [transport.compactLabel, displayHost]
        if usesPunycode && asciiHost.caseInsensitiveCompare(host) != .orderedSame {
            lines.append("Encoded host: \(asciiHost)")
        }
        if mixedScript {
            lines.append("This hostname mixes writing systems and may imitate another site.")
        }
        if transport == .http {
            lines.append("This connection is not encrypted.")
        }
        return lines.joined(separator: "\n")
    }

    static func inspect(_ line: String) -> TrustedOrigin? {
        inspect(URLComponents(string: line)?.url ?? URL(string: line))
    }

    static func inspect(_ url: URL?) -> TrustedOrigin? {
        guard let url else { return nil }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (parts?.scheme ?? url.scheme)?.lowercased() ?? ""
        if scheme.isEmpty || scheme == "about" { return nil }
        let host = (parts?.host ?? url.host)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        guard !host.isEmpty else { return nil }
        let ascii = asciiHost(host)
        let transport: Transport = scheme == "https" ? .https : scheme == "http" ? .http : .other
        return TrustedOrigin(
            url: url,
            scheme: scheme,
            host: host,
            asciiHost: ascii,
            registrableDomain: NavigationSafety.registrableDomain(ascii.contains("xn--") ? ascii : host),
            transport: transport,
            mixedScript: NavigationSafety.mixesWritingSystems(host)
        )
    }

    private static func asciiHost(_ host: String) -> String {
        if host.contains("xn--") { return host.lowercased() }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        if let encoded = parts.percentEncodedHost?.lowercased(), encoded.contains("xn--") {
            return encoded
        }
        var fromURL = URLComponents()
        fromURL.scheme = "https"
        fromURL.host = host
        return (URL(string: fromURL.string ?? "")?.host ?? host).lowercased()
    }
}
