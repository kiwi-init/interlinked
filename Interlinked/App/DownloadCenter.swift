import AppKit
import Observation
@preconcurrency import UserNotifications
import WebKit

@MainActor
@Observable
final class DownloadCenter: NSObject, WKDownloadDelegate {
    private(set) var records: [DownloadRecord]
    var panelOpen = false
    private(set) var unreadCount = 0
    private(set) var notificationStatus = "Checking…"

    @ObservationIgnored private var downloads: [UUID: WKDownload] = [:]
    @ObservationIgnored private var ids: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var observations: [UUID: [NSKeyValueObservation]] = [:]
    @ObservationIgnored private let storageURL: URL

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Interlinked", isDirectory: true)
        storageURL = base.appendingPathComponent("downloads.json")
        if let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = saved.map { record in
                guard record.state.isActive else { return record }
                var interrupted = record
                interrupted.state = .interrupted
                interrupted.message = "The app quit before this download finished."
                interrupted.finishedAt = Date()
                return interrupted
            }
        } else {
            records = []
        }
        super.init()
        persist()
    }

    var activeCount: Int { records.count(where: { $0.state.isActive }) }

    func togglePanel() {
        panelOpen.toggle()
        if panelOpen { unreadCount = 0 }
    }
    func closePanel() { panelOpen = false }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.notificationStatus = Self.notificationLabel(settings.authorizationStatus)
            }
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshNotificationStatus() }
        }
    }

    func track(_ download: WKDownload) {
        let url = download.originalRequest?.url
        let filename = DownloadNaming.sanitized(url?.lastPathComponent ?? "Download")
        let origin = url.flatMap(Self.origin) ?? "Unknown origin"
        let record = DownloadRecord(
            id: UUID(), filename: filename, origin: origin, destination: nil,
            state: .choosingDestination, fractionCompleted: nil, receivedBytes: 0,
            expectedBytes: nil, message: nil, resumeData: nil, startedAt: Date(), finishedAt: nil
        )
        records.insert(record, at: 0)
        attach(download, to: record.id)
        persist()
    }

    func cancel(_ id: UUID) {
        guard let download = downloads[id] else { return }
        update(id) {
            $0.state = .cancelled
            $0.message = "Cancelling…"
        }
        download.cancel { [weak self] data in
            guard let self else { return }
            self.update(id) {
                $0.state = .cancelled
                $0.message = "Download cancelled."
                $0.resumeData = data
                $0.finishedAt = Date()
            }
            self.release(id)
        }
    }

    func resume(_ id: UUID, in webView: WKWebView?) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let data = records[index].resumeData, let webView else { return }
        records[index].state = .choosingDestination
        records[index].message = "Resuming…"
        records[index].finishedAt = nil
        records[index].resumeData = nil
        persist()
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            self?.attach(download, to: id)
        }
    }

    func reveal(_ id: UUID) {
        guard let url = records.first(where: { $0.id == id })?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearFinished() {
        let removed = Set(records.filter { !$0.state.isActive }.map(\.id))
        records.removeAll { removed.contains($0.id) }
        persist()
    }

    func prepareForTermination() {
        for id in downloads.keys {
            update(id) {
                $0.state = .interrupted
                $0.message = "The app quit before this download finished."
                $0.finishedAt = Date()
            }
            downloads[id]?.cancel { [weak self] data in
                guard let data else { return }
                self?.update(id) { $0.resumeData = data }
            }
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard let id = ids[ObjectIdentifier(download)] else {
            completionHandler(nil)
            return
        }
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let proposed = DownloadNaming.availableURL(directory: directory, suggestedFilename: suggestedFilename)
        update(id) {
            $0.filename = proposed.lastPathComponent
            $0.expectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = proposed.lastPathComponent
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self else {
                completionHandler(nil)
                return
            }
            guard result == .OK, let url = panel.url else {
                self.update(id) {
                    $0.state = .cancelled
                    $0.message = "Download cancelled before it started."
                    $0.finishedAt = Date()
                }
                self.release(id)
                completionHandler(nil)
                return
            }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                self.update(id) {
                    $0.state = .failed
                    $0.message = "A file already exists at the chosen destination. Choose a different name."
                    $0.finishedAt = Date()
                }
                self.release(id)
                completionHandler(nil)
                return
            }
            self.update(id) {
                $0.destination = url
                $0.filename = url.lastPathComponent
                $0.state = .downloading
                $0.message = nil
            }
            completionHandler(url)
        }
        if let window = download.webView?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Task { @MainActor in
            let result = await WebPrompts.authenticationResponse(for: challenge, window: download.webView?.window)
            completionHandler(result.0, result.1)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = ids[ObjectIdentifier(download)] else { return }
        let filename = records.first(where: { $0.id == id })?.filename ?? "Download"
        update(id) {
            $0.state = .completed
            $0.fractionCompleted = 1
            $0.message = "Finished"
            $0.finishedAt = Date()
            $0.resumeData = nil
        }
        release(id)
        notify(title: "Download finished", body: filename)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = ids[ObjectIdentifier(download)] else { return }
        let nsError = error as NSError
        let previousState = records.first(where: { $0.id == id })?.state
        let wasCancelled = previousState == .cancelled
        let wasInterrupted = previousState == .interrupted
        let message = wasInterrupted
            ? "The app quit before this download finished."
            : wasCancelled ? "Download cancelled." : DownloadFailure.message(for: nsError)
        update(id) {
            $0.state = wasInterrupted ? .interrupted : wasCancelled ? .cancelled : .failed
            $0.message = message
            $0.resumeData = resumeData
            $0.finishedAt = Date()
        }
        let filename = records.first(where: { $0.id == id })?.filename ?? "Download"
        release(id)
        if !wasCancelled && !wasInterrupted { notify(title: "Download failed", body: "\(filename): \(message)") }
    }

    private func attach(_ download: WKDownload, to id: UUID) {
        download.delegate = self
        downloads[id] = download
        ids[ObjectIdentifier(download)] = id
        let progress = download.progress
        observations[id] = [
            progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
                Task { @MainActor in self?.publish(progress, id: id) }
            },
            progress.observe(\.totalUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
                Task { @MainActor in self?.publish(progress, id: id) }
            }
        ]
    }

    private func publish(_ progress: Progress, id: UUID) {
        update(id, persist: false) {
            $0.receivedBytes = progress.completedUnitCount
            if progress.totalUnitCount > 0 {
                $0.expectedBytes = progress.totalUnitCount
                $0.fractionCompleted = min(max(progress.fractionCompleted, 0), 1)
            } else {
                $0.expectedBytes = nil
                $0.fractionCompleted = nil
            }
        }
    }

    private func update(_ id: UUID, persist shouldPersist: Bool = true, change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        if shouldPersist { persist() }
    }

    private func release(_ id: UUID) {
        if let download = downloads.removeValue(forKey: id) {
            ids.removeValue(forKey: ObjectIdentifier(download))
        }
        observations.removeValue(forKey: id)
    }

    private func persist() {
        records = Array(records.prefix(100))
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Downloading must continue even when history cannot be persisted.
        }
    }

    private func notify(title: String, body: String) {
        if !panelOpen { unreadCount += 1 }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func notificationLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Denied in System Settings"
        case .notDetermined: return "Off"
        @unknown default: return "Unavailable"
        }
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var result = "\(scheme)://\(host)"
        if let port = url.port { result += ":\(port)" }
        return result
    }
}
