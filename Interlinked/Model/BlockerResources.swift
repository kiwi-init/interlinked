import Foundation

/// uBlock Origin's scriptlets and stand-in resources, as the blocker engine
/// reads them. The app bundles a copy made by script/build-blocker-resources.
/// A build may also name a remote copy (INTERLINKED_BLOCKER_RESOURCES_URL), so
/// scriptlets that new filters depend on arrive without an app release; it is
/// refreshed with the filter lists and replaces the bundled copy only once it
/// passes `validated`.
enum BlockerResources {
    /// The bundled copy is about 0.5 MB.
    static let maximumBytes = 8 * 1024 * 1024
    /// The bundled copy has about 200 resources; far fewer means a broken file.
    static let minimumCount = 100

    static var remoteURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "InterlinkedBlockerResourcesURL") as? String,
              !raw.isEmpty, !raw.contains("$("), let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    /// The remote copy saved at |cache| while it is still valid, else the
    /// bundled one.
    static func load(cache: URL?, bundled: URL?) -> String {
        if let cache, let data = try? Data(contentsOf: cache), let json = validated(data) {
            return json
        }
        return bundled.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "[]"
    }

    /// Downloads |url| and saves it at |cache| when it is valid. A failed or
    /// invalid download changes nothing.
    static func refresh(from url: URL, cache: URL, session: URLSession = .shared) async {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadRevalidatingCacheData
        guard let (bytes, response) = try? await session.bytes(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= maximumBytes else { return }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maximumBytes { return }
            }
        } catch {
            return
        }
        guard validated(data) != nil else { return }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cache, options: .atomic)
    }

    /// |data| as JSON text when it is a resource list the engine can load.
    static func validated(_ data: Data) -> String? {
        guard data.count <= maximumBytes,
              let resources = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              resources.count >= minimumCount,
              resources.allSatisfy(isResource) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The fields adblock-rust's `Resource` needs, with base64 content.
    private static func isResource(_ resource: [String: Any]) -> Bool {
        let strings = { (key: String) in resource[key] == nil || resource[key] is [String] }
        guard let name = resource["name"] as? String, !name.isEmpty,
              let content = resource["content"] as? String, Data(base64Encoded: content) != nil,
              strings("aliases"), strings("dependencies"),
              isPermission(resource["permission"]) else { return false }
        switch resource["kind"] {
        case let kind as [String: Any]: return kind["mime"] is String
        case let kind as String: return kind == "template"
        default: return false
        }
    }

    /// The engine reads a permission as one byte and drops the whole list over
    /// anything else. JSON `true` would otherwise pass as the Int 1.
    private static func isPermission(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return false }
        return (0...255).contains(number.intValue)
    }
}
