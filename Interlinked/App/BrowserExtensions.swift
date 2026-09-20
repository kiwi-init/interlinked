import AppKit
import Observation
import UniformTypeIdentifiers

/// Stores unpacked Manifest V3 extensions for Chromium's startup loader.
/// CEF does not expose a runtime extension loader, so changes apply after restart.
@MainActor
@Observable
final class BrowserExtensionRuntime {
    private(set) var records: [BrowserExtensionRecord] = []
    private(set) var busy = false
    private(set) var message = ""
    private(set) var requiresRestart = false

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let libraryOverride: URL?

    init(fileManager: FileManager = .default, libraryURL: URL? = nil) {
        self.fileManager = fileManager
        libraryOverride = libraryURL
    }

    var isAvailable: Bool { ILChromiumRuntime.supportsManifestV3Extensions }
    var supportsChromeWebStore: Bool { false }

    func start(workspace: Workspace) {
        guard self.workspace == nil else { return }
        self.workspace = workspace
        records = readRecords()
        removeOrphanedManagedDirectories()
        validateRecords()
        if !isAvailable {
            message = BrowserExtensionFailure.unavailable.localizedDescription
        } else if records.contains(where: \.enabled) {
            message = "Enabled extensions were passed to Chromium at launch."
        }
    }

    func stop() {
        workspace = nil
    }

    func installFromPanel() {
        guard isAvailable else {
            message = BrowserExtensionFailure.unavailable.localizedDescription
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Add Manifest V3 Extension"
        panel.message = "Choose an unpacked extension folder containing manifest.json."
        panel.prompt = "Add Extension"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await install(from: url) }
    }

    func install(from sourceURL: URL) async {
        guard isAvailable else {
            message = BrowserExtensionFailure.unavailable.localizedDescription
            return
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            message = BrowserExtensionFailure.archiveUnsupported.localizedDescription
            return
        }

        busy = true
        message = "Reading extension…"
        defer { busy = false }

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            let manifest = try BrowserExtensionManifest.read(from: sourceURL, fileManager: fileManager)
            guard approveInstall(manifest) else {
                message = "Installation cancelled."
                return
            }

            let extensionID = UUID()
            let managedURL = try copyIntoLibrary(sourceURL, id: extensionID)
            do {
                _ = try BrowserExtensionManifest.read(from: managedURL, fileManager: fileManager)
            } catch {
                try? fileManager.removeItem(at: extensionDirectory(extensionID))
                throw error
            }
            let record = record(for: manifest, id: extensionID, sourceURL: sourceURL, managedURL: managedURL)
            records.append(record)
            records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            writeRecords()
            markRestartRequired("\(record.name) will load after Interlinked restarts.")
        } catch {
            message = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].enabled != enabled else { return }
        records[index].enabled = enabled
        writeRecords()
        markRestartRequired("Restart Interlinked to \(enabled ? "enable" : "disable") \(records[index].name).")
    }

    func uninstall(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        writeRecords()
        markRestartRequired("Restart Interlinked to finish removing \(record.name).")
    }

    fileprivate var libraryURL: URL {
        if let libraryOverride { return libraryOverride }
        return BrowserExtensionCatalog.defaultLibraryURL(fileManager: fileManager)
    }

    private var recordsURL: URL { libraryURL.appendingPathComponent("extensions.json") }

    private func approveInstall(_ manifest: BrowserExtensionManifest) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add \(manifest.name)?"
        let details = manifest.permissions.map { "Permission: \($0)" } + manifest.hosts.map { "Website access: \($0)" }
        alert.informativeText = details.isEmpty ? "This extension did not request additional access." : details.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func record(
        for manifest: BrowserExtensionManifest,
        id: UUID,
        sourceURL: URL,
        managedURL: URL
    ) -> BrowserExtensionRecord {
        let relative = managedURL.path.replacingOccurrences(of: libraryURL.path + "/", with: "")
        return BrowserExtensionRecord(
            id: id,
            name: manifest.name,
            version: manifest.version,
            sourceName: sourceURL.lastPathComponent,
            relativePath: relative,
            enabled: true,
            requestedPermissions: manifest.permissions,
            optionalPermissions: manifest.optionalPermissions,
            requestedHosts: manifest.hosts,
            optionalHosts: manifest.optionalHosts,
            grantedPermissions: manifest.permissions,
            grantedHosts: manifest.hosts,
            deniedPermissions: [],
            deniedHosts: [],
            errors: []
        )
    }

    private func extensionDirectory(_ id: UUID) -> URL {
        libraryURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func copyIntoLibrary(_ sourceURL: URL, id: UUID) throws -> URL {
        try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let directory = extensionDirectory(id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func readRecords() -> [BrowserExtensionRecord] {
        BrowserExtensionCatalog.readRecords(in: libraryURL)
    }

    private func validateRecords() {
        var changed = false
        for index in records.indices {
            let source = libraryURL.appendingPathComponent(records[index].relativePath, isDirectory: true)
            do {
                _ = try BrowserExtensionManifest.read(from: source, fileManager: fileManager)
                if !records[index].errors.isEmpty {
                    records[index].errors = []
                    changed = true
                }
            } catch {
                let errors = [error.localizedDescription]
                if records[index].errors != errors {
                    records[index].errors = errors
                    changed = true
                }
            }
        }
        if changed { writeRecords() }
    }

    private func removeOrphanedManagedDirectories() {
        let retained = Set(records.map(\.id))
        guard let contents = try? fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in contents {
            guard let id = UUID(uuidString: directory.lastPathComponent), !retained.contains(id),
                  fileManager.fileExists(atPath: directory.appendingPathComponent("unpacked").path) else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func writeRecords() {
        do {
            try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: recordsURL, options: .atomic)
        } catch {
            message = "Couldn’t save extension settings: \(error.localizedDescription)"
        }
    }

    private func markRestartRequired(_ message: String) {
        requiresRestart = true
        self.message = message
    }
}
