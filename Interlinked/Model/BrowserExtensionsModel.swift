import Foundation

struct BrowserExtensionRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var version: String
    var sourceName: String
    var relativePath: String
    var enabled: Bool
    var requestedPermissions: [String]
    var optionalPermissions: [String]
    var requestedHosts: [String]
    var optionalHosts: [String]
    var grantedPermissions: [String]
    var grantedHosts: [String]
    var deniedPermissions: [String]?
    var deniedHosts: [String]?
    var errors: [String]
}

enum BrowserExtensionFailure: LocalizedError, Equatable {
    case unavailable
    case manifestMissing
    case manifestUnreadable
    case manifestVersion(Int)
    case missingSource
    case archiveUnsupported

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This Chromium build cannot load extensions."
        case .manifestMissing:
            "The selected folder does not contain manifest.json."
        case .manifestUnreadable:
            "The extension manifest is not valid JSON."
        case .manifestVersion(let version):
            "This is a Manifest V\(version) extension. Interlinked loads Manifest V3 extensions."
        case .missingSource:
            "The extension files are missing. Reinstall it."
        case .archiveUnsupported:
            "Choose an unpacked extension folder. CRX and ZIP installation is not available in embedded Chromium."
        }
    }
}

struct BrowserExtensionManifest: Equatable {
    var name: String
    var version: String
    var permissions: [String]
    var optionalPermissions: [String]
    var hosts: [String]
    var optionalHosts: [String]

    static func read(from directory: URL, fileManager: FileManager = .default) throws -> Self {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BrowserExtensionFailure.missingSource
        }

        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw BrowserExtensionFailure.manifestMissing
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserExtensionFailure.manifestUnreadable
        }

        let manifestVersion: Int
        if let value = manifest["manifest_version"] as? Int {
            manifestVersion = value
        } else if let value = manifest["manifest_version"] as? NSNumber {
            manifestVersion = value.intValue
        } else {
            throw BrowserExtensionFailure.manifestUnreadable
        }
        guard manifestVersion == 3 else {
            throw BrowserExtensionFailure.manifestVersion(manifestVersion)
        }

        let rawName = manifest["name"] as? String ?? directory.lastPathComponent
        let name = localized(rawName, manifest: manifest, directory: directory) ?? rawName
        return Self(
            name: name,
            version: manifest["version"] as? String ?? "",
            permissions: strings(manifest["permissions"]),
            optionalPermissions: strings(manifest["optional_permissions"]),
            hosts: strings(manifest["host_permissions"]),
            optionalHosts: strings(manifest["optional_host_permissions"])
        )
    }

    private static func strings(_ value: Any?) -> [String] {
        Array(Set(value as? [String] ?? [])).sorted()
    }

    private static func localized(_ value: String, manifest: [String: Any], directory: URL) -> String? {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__"),
              let locale = manifest["default_locale"] as? String else { return nil }
        let key = String(value.dropFirst(6).dropLast(2))
        let messagesURL = directory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent("messages.json", isDirectory: false)
        guard let data = try? Data(contentsOf: messagesURL),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = messages[key] as? [String: Any] else { return nil }
        return entry["message"] as? String
    }
}

enum BrowserExtensionCatalog {
    static func defaultLibraryURL(fileManager: FileManager = .default) -> URL {
        let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (base ?? fileManager.temporaryDirectory)
            .appendingPathComponent("Interlinked", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }

    static func recordsURL(in libraryURL: URL) -> URL {
        libraryURL.appendingPathComponent("extensions.json", isDirectory: false)
    }

    static func readRecords(in libraryURL: URL) -> [BrowserExtensionRecord] {
        guard let data = try? Data(contentsOf: recordsURL(in: libraryURL)),
              let records = try? JSONDecoder().decode([BrowserExtensionRecord].self, from: data) else { return [] }
        return records
    }

    static func startupExtensionPaths(
        in libraryURL: URL = defaultLibraryURL(),
        fileManager: FileManager = .default
    ) -> [String] {
        let library = libraryURL.standardizedFileURL
        let prefix = library.path + "/"
        return readRecords(in: library).compactMap { record in
            guard record.enabled, !record.relativePath.isEmpty else { return nil }
            let extensionURL = library.appendingPathComponent(record.relativePath, isDirectory: true).standardizedFileURL
            guard extensionURL.path.hasPrefix(prefix), !extensionURL.path.contains(",") else { return nil }
            guard (try? BrowserExtensionManifest.read(from: extensionURL, fileManager: fileManager)) != nil else { return nil }
            return extensionURL.path
        }
    }
}
