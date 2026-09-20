import XCTest

final class WebExtensionTests: XCTestCase {
    func testManifestV3ReadsChromiumPermissionsAndHosts() throws {
        let root = try extensionDirectory(manifest: [
            "manifest_version": 3,
            "name": "Interlinked Test Extension",
            "version": "1.2.3",
            "permissions": ["storage", "scripting", "storage"],
            "optional_permissions": ["tabs"],
            "host_permissions": ["https://example.com/*"],
            "optional_host_permissions": ["https://optional.example/*"],
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try BrowserExtensionManifest.read(from: root)

        XCTAssertEqual(manifest.name, "Interlinked Test Extension")
        XCTAssertEqual(manifest.version, "1.2.3")
        XCTAssertEqual(manifest.permissions, ["scripting", "storage"])
        XCTAssertEqual(manifest.optionalPermissions, ["tabs"])
        XCTAssertEqual(manifest.hosts, ["https://example.com/*"])
        XCTAssertEqual(manifest.optionalHosts, ["https://optional.example/*"])
    }

    func testLocalizedManifestNameIsResolved() throws {
        let root = try extensionDirectory(manifest: [
            "manifest_version": 3,
            "name": "__MSG_extensionName__",
            "version": "1.0",
            "default_locale": "en",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let locale = root.appendingPathComponent("_locales/en", isDirectory: true)
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        let messages = try JSONSerialization.data(withJSONObject: [
            "extensionName": ["message": "Localized Extension"],
        ])
        try messages.write(to: locale.appendingPathComponent("messages.json"))

        XCTAssertEqual(try BrowserExtensionManifest.read(from: root).name, "Localized Extension")
    }

    func testManifestV2IsRejected() throws {
        let root = try extensionDirectory(manifest: [
            "manifest_version": 2,
            "name": "Old Extension",
            "version": "1.0",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try BrowserExtensionManifest.read(from: root)) { error in
            XCTAssertEqual(error as? BrowserExtensionFailure, .manifestVersion(2))
        }
    }

    func testChromiumStartupCatalogIncludesOnlyEnabledValidManifestV3Folders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterlinkedExtensionCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let enabled = root.appendingPathComponent("enabled", isDirectory: true)
        let disabled = root.appendingPathComponent("disabled", isDirectory: true)
        let old = root.appendingPathComponent("old", isDirectory: true)
        for directory in [enabled, disabled, old] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeManifest(version: 3, to: enabled)
        try writeManifest(version: 3, to: disabled)
        try writeManifest(version: 2, to: old)

        let records = [
            record(enabled: true, relativePath: "enabled"),
            record(enabled: false, relativePath: "disabled"),
            record(enabled: true, relativePath: "old"),
            record(enabled: true, relativePath: "../outside"),
        ]
        try JSONEncoder().encode(records).write(to: BrowserExtensionCatalog.recordsURL(in: root))

        XCTAssertEqual(BrowserExtensionCatalog.startupExtensionPaths(in: root), [enabled.path])
    }

    private func extensionDirectory(manifest: [String: Any]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterlinkedExtensionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("manifest.json"))
        return root
    }

    private func writeManifest(version: Int, to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "manifest_version": version,
            "name": "Test",
            "version": "1.0",
        ])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func record(enabled: Bool, relativePath: String) -> BrowserExtensionRecord {
        BrowserExtensionRecord(
            id: UUID(),
            name: "Test",
            version: "1.0",
            sourceName: "Test",
            relativePath: relativePath,
            enabled: enabled,
            requestedPermissions: [],
            optionalPermissions: [],
            requestedHosts: [],
            optionalHosts: [],
            grantedPermissions: [],
            grantedHosts: [],
            deniedPermissions: [],
            deniedHosts: [],
            errors: []
        )
    }
}
