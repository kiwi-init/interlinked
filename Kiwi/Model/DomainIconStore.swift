import CryptoKit
import Foundation

/// Persists successful favicon responses so the in-memory cache can survive relaunches.
struct DomainIconStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kiwi/Favicons", isDirectory: true)
    }

    func data(for domain: String) -> Data? {
        try? Data(contentsOf: file(for: domain))
    }

    func write(_ data: Data, for domain: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(for: domain), options: .atomic)
    }

    func remove(_ domain: String) {
        try? FileManager.default.removeItem(at: file(for: domain))
    }

    private func file(for domain: String) -> URL {
        let digest = SHA256.hash(data: Data(domain.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("icon")
    }
}
