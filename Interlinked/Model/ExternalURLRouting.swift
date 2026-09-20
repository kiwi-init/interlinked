import Foundation

enum ExternalURLDestination: Equatable {
    case reuseActivePage
    case newPage
}

struct ExternalURLRoute: Equatable {
    var url: URL
    var destination: ExternalURLDestination
}

enum ExternalURLRouting {
    static func routes(for urls: [URL], canReuseActivePage: Bool) -> [ExternalURLRoute] {
        var canReuse = canReuseActivePage
        return urls.compactMap { url in
            guard let url = webURL(url) else { return nil }
            let destination: ExternalURLDestination = canReuse ? .reuseActivePage : .newPage
            canReuse = false
            return ExternalURLRoute(url: url, destination: destination)
        }
    }

    static func webURL(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty else { return nil }
        return url
    }
}
