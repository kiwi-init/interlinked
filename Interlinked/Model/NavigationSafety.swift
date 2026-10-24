import Foundation

enum NavigationSafety {
    /// A `javascript:` or `data:` address never opens as a page, as in other
    /// browsers. A page saving a `data:` or `blob:` file it made itself is not
    /// opening it.
    static func blocks(_ destination: URL, download: Bool = false) -> Bool {
        let scheme = destination.scheme?.lowercased() ?? ""
        if download, ["data", "blob"].contains(scheme) { return false }
        return ["javascript", "data"].contains(scheme)
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var value = "\(scheme)://\(host)"
        if let port = url.port { value += ":\(port)" }
        return value
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

    static func registrableDomain(_ host: String) -> String {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        if isIPAddress(value) { return value }
        let labels = value.split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let twoLevelSuffixes: Set<String> = ["co.uk", "org.uk", "com.br", "com.au", "co.jp", "co.nz", "com.mx", "com.sg"]
        let suffix = labels.suffix(2).joined(separator: ".")
        return twoLevelSuffixes.contains(suffix) ? labels.suffix(3).joined(separator: ".") : suffix
    }
}
