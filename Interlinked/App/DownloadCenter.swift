import AppKit
import Observation
@preconcurrency import UserNotifications

private struct ChromiumDownloadKey: Hashable {
    let page: ObjectIdentifier
    let identifier: UInt32
}

private final class ActiveChromiumDownload {
    weak var page: ChromiumPage?
    let identifier: UInt32

    init(page: ChromiumPage, identifier: UInt32) {
        self.page = page
        self.identifier = identifier
    }
}

@MainActor
@Observable
final class DownloadCenter {
    private(set) var records: [DownloadRecord]
    var panelOpen = false
    private(set) var unreadCount = 0
    private(set) var notificationStatus = "Checking…"

    @ObservationIgnored private var active: [UUID: ActiveChromiumDownload] = [:]
    @ObservationIgnored private var recordIDs: [ChromiumDownloadKey: UUID] = [:]
    @ObservationIgnored private let storageURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Interlinked", isDirectory: true)
        storageURL = base.appendingPathComponent("downloads.json")
        if let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = saved.map { record in
                var migrated = record
                migrated.resumeData = nil
                if record.state.isActive {
                    migrated.state = .interrupted
                    migrated.message = "The app quit before this download finished."
                    migrated.finishedAt = Date()
                }
                return migrated
            }
        } else {
            records = []
        }
        persist()
    }

    var activeCount: Int { records.count(where: { $0.state.isActive }) }

    func hasActiveDownload(for page: ChromiumPage) -> Bool {
        active.values.contains { $0.page === page }
    }

    func begin(page: ChromiumPage, identifier: UInt32, url: URL, suggestedFilename: String) {
        let key = ChromiumDownloadKey(page: ObjectIdentifier(page), identifier: identifier)
        guard recordIDs[key] == nil else { return }
        let id = UUID()
        recordIDs[key] = id
        active[id] = ActiveChromiumDownload(page: page, identifier: identifier)
        records.insert(DownloadRecord(
            id: id, filename: DownloadNaming.sanitized(suggestedFilename),
            origin: Self.origin(url) ?? "Unknown origin", destination: nil,
            state: .choosingDestination, fractionCompleted: nil, receivedBytes: 0,
            expectedBytes: nil, message: nil, resumeData: nil,
            startedAt: Date(), finishedAt: nil
        ), at: 0)
        persist()
    }

    func update(page: ChromiumPage, identifier: UInt32, fullPath: String, receivedBytes: Int64,
                totalBytes: Int64, percent: Int, complete: Bool, cancelled: Bool, interrupted: Bool) {
        let key = ChromiumDownloadKey(page: ObjectIdentifier(page), identifier: identifier)
        guard let id = recordIDs[key] else { return }
        update(id, persist: complete || cancelled || interrupted) {
            if !fullPath.isEmpty {
                $0.destination = URL(fileURLWithPath: fullPath)
                $0.filename = URL(fileURLWithPath: fullPath).lastPathComponent
            }
            $0.receivedBytes = receivedBytes
            $0.expectedBytes = totalBytes > 0 ? totalBytes : nil
            $0.fractionCompleted = percent >= 0 ? Double(percent) / 100 : nil
            if complete {
                $0.state = .completed; $0.fractionCompleted = 1; $0.message = "Finished"; $0.finishedAt = Date()
            } else if cancelled {
                $0.state = .cancelled; $0.message = "Download cancelled."; $0.finishedAt = Date()
            } else if interrupted {
                $0.state = .interrupted; $0.message = "Download interrupted."; $0.finishedAt = Date()
            } else {
                $0.state = fullPath.isEmpty ? .choosingDestination : .downloading
            }
        }
        if complete || cancelled || interrupted {
            let filename = records.first(where: { $0.id == id })?.filename ?? "Download"
            active.removeValue(forKey: id)
            recordIDs.removeValue(forKey: key)
            if complete { notify(title: "Download finished", body: filename) }
            if interrupted { notify(title: "Download failed", body: filename) }
        }
    }

    func cancel(_ id: UUID) {
        guard let download = active[id] else { return }
        update(id) { $0.message = "Cancelling…" }
        download.page?.cancelDownload(download.identifier)
    }

    func reveal(_ id: UUID) {
        guard let url = records.first(where: { $0.id == id })?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearFinished() { records.removeAll { !$0.state.isActive }; persist() }
    func togglePanel() { panelOpen.toggle(); if panelOpen { unreadCount = 0 } }
    func closePanel() { panelOpen = false }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in self?.notificationStatus = Self.notificationLabel(settings.authorizationStatus) }
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshNotificationStatus() }
        }
    }

    func prepareForTermination() {
        for (id, download) in active {
            update(id) { $0.state = .interrupted; $0.message = "The app quit before this download finished."; $0.finishedAt = Date() }
            download.page?.cancelDownload(download.identifier)
        }
        active.removeAll(); recordIDs.removeAll()
    }

    private func update(_ id: UUID, persist shouldPersist: Bool = true, change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        if shouldPersist { persist() }
    }

    private func persist() {
        records = Array(records.prefix(100))
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: storageURL, options: .atomic)
        } catch { }
    }

    private func notify(title: String, body: String) {
        if !panelOpen { unreadCount += 1 }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent(); content.title = title; content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func notificationLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Denied in System Settings"
        case .notDetermined: "Off"
        @unknown default: "Unavailable"
        }
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var result = "\(scheme)://\(host)"; if let port = url.port { result += ":\(port)" }; return result
    }
}
