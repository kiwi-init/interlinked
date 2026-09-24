import Foundation
import Observation

enum IntelligenceAuditOutcome: String, Codable, Sendable {
    case running
    case completed
    case failed
    case interrupted

    var label: String {
        switch self {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    var symbol: String {
        switch self {
        case .running: "ellipsis.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        }
    }
}

struct IntelligenceAuditEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var source: IntelligenceSource
    var action: String
    var startedAt: Date
    var finishedAt: Date?
    var outcome: IntelligenceAuditOutcome
    var durationMilliseconds: Int?
}

private struct IntelligenceAuditExport: Codable {
    var formatVersion = 1
    var exportedAt: Date
    var privacyNote = "Metadata only. Interlinked does not record prompts, page text, URLs, queries, model responses, credentials, or error messages in this file."
    var events: [IntelligenceAuditEvent]
}

/// A local, metadata-only record of intelligence activity.
///
/// The interface deliberately accepts no page content, user input, URLs,
/// responses, credentials, or errors so those values cannot enter the ledger.
@MainActor @Observable
final class IntelligenceAuditStore {
    static let shared = IntelligenceAuditStore(file: defaultFile())
    /// The oldest events are dropped past this count so every write stays small.
    static let eventLimit = 2_000

    private(set) var events: [IntelligenceAuditEvent] = []
    @ObservationIgnored private let writer: IntelligenceAuditWriter?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(file: URL? = nil, now: @escaping () -> Date = Date.init, saveDelay: Duration = .seconds(1)) {
        writer = file.map(IntelligenceAuditWriter.init)
        self.now = now
        self.saveDelay = saveDelay
        events = Array((writer?.load() ?? []).prefix(Self.eventLimit))
        recoverInterruptedActions()
    }

    var recent: [IntelligenceAuditEvent] { Array(events.prefix(20)) }
    var isEmpty: Bool { events.isEmpty }

    @discardableResult
    func begin(source: IntelligenceSource, action: String) -> UUID {
        let event = IntelligenceAuditEvent(
            id: UUID(),
            source: source,
            action: action,
            startedAt: now(),
            finishedAt: nil,
            outcome: .running,
            durationMilliseconds: nil
        )
        events.insert(event, at: 0)
        if events.count > Self.eventLimit {
            events.removeLast(events.count - Self.eventLimit)
        }
        scheduleSave()
        return event.id
    }

    func finish(_ id: UUID, failed: Bool) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let finishedAt = now()
        events[index].finishedAt = finishedAt
        events[index].outcome = failed ? .failed : .completed
        events[index].durationMilliseconds = max(
            0,
            Int(finishedAt.timeIntervalSince(events[index].startedAt) * 1_000)
        )
        scheduleSave()
    }

    func clear() {
        events.removeAll()
        flush()
    }

    /// Writes the current events now, replacing any pending debounced save.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let writer else { return }
        generation += 1
        writer.write(events, generation: generation)
    }

    /// Waits for the pending debounced save, if any, to reach the disk.
    func waitForPendingSave() async {
        await saveTask?.value
    }

    /// Completed writes to the file, for tests.
    var writeCount: Int { writer?.writeCount ?? 0 }

    func export(to destination: URL) throws {
        let payload = IntelligenceAuditExport(
            exportedAt: now(),
            events: Array(events.reversed())
        )
        let data = try IntelligenceAuditWriter.encoder.encode(payload)
        try data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func recoverInterruptedActions() {
        let finishedAt = now()
        var changed = false
        for index in events.indices where events[index].outcome == .running {
            events[index].outcome = .interrupted
            events[index].finishedAt = finishedAt
            events[index].durationMilliseconds = max(
                0,
                Int(finishedAt.timeIntervalSince(events[index].startedAt) * 1_000)
            )
            changed = true
        }
        if changed { flush() }
    }

    private func scheduleSave() {
        guard writer != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            do { try await Task.sleep(for: saveDelay) } catch { return }
            guard !Task.isCancelled, let self, let writer = self.writer else { return }
            self.generation += 1
            let events = self.events, generation = self.generation
            await Task.detached(priority: .utility) {
                writer.write(events, generation: generation)
            }.value
        }
    }

    private static func defaultFile() -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory
            .appendingPathComponent("Interlinked", isDirectory: true)
            .appendingPathComponent("IntelligenceActivity.json")
    }
}

/// Encodes and writes audit snapshots off the main actor. Writes run one at a
/// time, and a snapshot older than the last one written is dropped, so a slow
/// debounced save cannot overwrite a newer flush such as `clear()`.
private final class IntelligenceAuditWriter: @unchecked Sendable {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let file: URL
    private let lock = NSLock()
    private var writtenGeneration = 0
    private var completedWrites = 0

    init(file: URL) {
        self.file = file
    }

    var writeCount: Int { lock.withLock { completedWrites } }

    /// Saved events, newest first.
    func load() -> [IntelligenceAuditEvent] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([IntelligenceAuditEvent].self, from: data))?
            .sorted { $0.startedAt > $1.startedAt } ?? []
    }

    func write(_ events: [IntelligenceAuditEvent], generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation > writtenGeneration else { return }
        writtenGeneration = generation
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try Self.encoder.encode(events)
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            completedWrites += 1
        } catch {
            // Auditing must never interrupt the browser action it observes.
        }
    }
}
