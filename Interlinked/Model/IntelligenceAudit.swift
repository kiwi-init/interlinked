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

    private(set) var events: [IntelligenceAuditEvent] = []
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let now: () -> Date

    init(file: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
        events = load()
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
        persist()
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
        persist()
    }

    func clear() {
        events.removeAll()
        persist()
    }

    func export(to destination: URL) throws {
        let payload = IntelligenceAuditExport(
            exportedAt: now(),
            events: Array(events.reversed())
        )
        let data = try Self.encoder.encode(payload)
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
        if changed { persist() }
    }

    private func load() -> [IntelligenceAuditEvent] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([IntelligenceAuditEvent].self, from: data))?
            .sorted { $0.startedAt > $1.startedAt } ?? []
    }

    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try Self.encoder.encode(events)
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // Auditing must never interrupt the browser action it observes.
        }
    }

    private static let encoder: JSONEncoder = {
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

    private static func defaultFile() -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory
            .appendingPathComponent("Interlinked", isDirectory: true)
            .appendingPathComponent("IntelligenceActivity.json")
    }
}
