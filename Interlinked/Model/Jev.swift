import Foundation
import CryptoKit
import StoreKit

struct JevQuestion: Codable, Sendable {
    enum Kind: String, Codable { case choice, noul, score }
    var type: Kind
    var instructions: String
    var criteria: [String: String]
    var levels: [String]? = nil

    private enum CodingKeys: String, CodingKey { case type, instructions, criteria }
    init(type: Kind, instructions: String, criteria: [String: String], levels: [String]? = nil) {
        self.type = type; self.instructions = instructions; self.criteria = criteria; self.levels = levels
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(Kind.self, forKey: .type); instructions = try c.decode(String.self, forKey: .instructions)
        if type == .score { levels = try c.decode([String].self, forKey: .criteria); criteria = [:] }
        else { criteria = try c.decode([String: String].self, forKey: .criteria) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type); try c.encode(instructions, forKey: .instructions)
        if type == .score { try c.encode(levels ?? [], forKey: .criteria) }
        else { try c.encode(criteria, forKey: .criteria) }
    }

    static func choice(_ instructions: String, _ options: [String: String]) -> Self {
        Self(type: .choice, instructions: instructions, criteria: options)
    }
    static func relevant(_ instructions: String) -> Self {
        Self(type: .noul, instructions: instructions, criteria: [
            "true": "The supplied evidence clearly supports the requested relationship.",
            "false": "The relationship is absent, ambiguous, or unsupported by the supplied evidence."
        ])
    }
}

struct JevRequest: Codable, Sendable {
    static let model = "typesafe/jev-1.13"
    var model = Self.model
    var state: String
    var questions: [String: JevQuestion]
    // Supported by OpenRouter's DecisionsRequest, independently of TypeSafe's direct API.
    var provider = ["data_collection": "deny"]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct JevAnswer: Codable, Sendable {
    var type: String
    var choice: String?
    var noul: Double?
    var score: Double?
    var confidence: Double?
    var probabilities: [String: Double]?
}
struct JevResponse: Codable, Sendable {
    var answers: [String: JevAnswer]

    func validated(for request: JevRequest) throws -> Self {
        guard Set(answers.keys) == Set(request.questions.keys) else { throw JevError.invalidResponse }
        for (id, question) in request.questions {
            guard let answer = answers[id], answer.type == question.type.rawValue else { throw JevError.invalidResponse }
            if let confidence = answer.confidence, !(0...1).contains(confidence) { throw JevError.invalidResponse }
            switch question.type {
            case .choice:
                guard let choice = answer.choice, question.criteria[choice] != nil else { throw JevError.invalidResponse }
                if let probabilities = answer.probabilities {
                    guard Set(probabilities.keys).isSubset(of: Set(question.criteria.keys)),
                          probabilities.values.allSatisfy({ (0...1).contains($0) }) else { throw JevError.invalidResponse }
                }
            case .noul:
                guard let value = answer.noul, (0...1).contains(value) else { throw JevError.invalidResponse }
            case .score:
                guard let value = answer.score, value.isFinite,
                      (0...Double(max(0, (question.levels?.count ?? 0) - 1))).contains(value) else { throw JevError.invalidResponse }
            }
        }
        return self
    }
}

enum JevError: Error, Equatable, LocalizedError {
    case noKey, disabled, busy, rateLimited, unavailable, invalidResponse, tooLarge
    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your OpenRouter key in Settings. Local browsing still works."
        case .disabled: return "Jev is off. Enable it in Settings to use meaning and reading tools."
        case .busy: return "Another request is running. Try again in a moment."
        case .rateLimited: return "OpenRouter is rate limiting requests. Try again in a minute."
        case .unavailable: return "Jev is unavailable. Local results are still available."
        case .invalidResponse: return "Jev returned an unusable decision. Local results are unchanged."
        case .tooLarge: return "This selection is too large to process."
        }
    }
}

protocol JevProvider: Sendable {
    func decide(_ request: JevRequest) async throws -> JevResponse
}

enum JevRuntime {
    static var relayEndpoint: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "InterlinkedJevRelayURL") as? String,
              !raw.isEmpty, !raw.contains("$("), let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }
    static var includesJev: Bool { relayEndpoint != nil }

    static func provider() -> any JevProvider {
        relayEndpoint.map { InterlinkedRelayJev(endpoint: $0) } ?? OpenRouterJev()
    }
}

struct OpenRouterJev: JevProvider {
    static let endpoint = URL(string: "https://openrouter.ai/api/alpha/decisions")!
    var session: URLSession = .shared
    var credential: @Sendable () throws -> String = { try JevCredential.read() }

    func decide(_ decision: JevRequest) async throws -> JevResponse {
        let key = try credential()
        guard !key.isEmpty else { throw JevError.noKey }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Interlinked", forHTTPHeaderField: "X-Title")
        request.httpBody = try decision.encoded()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw JevError.unavailable }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw JevError.noKey
        case 413: throw JevError.tooLarge
        case 429: throw JevError.rateLimited
        default: throw JevError.unavailable
        }
        guard let result = try? JSONDecoder().decode(JevResponse.self, from: data) else { throw JevError.invalidResponse }
        return try result.validated(for: decision)
    }
}

/// External builds use Interlinked's relay. The relay validates the signed
/// App Store transaction before spending the server-side OpenRouter key.
struct InterlinkedRelayJev: JevProvider {
    var endpoint: URL
    var session: URLSession = .shared
    var appTransaction: @Sendable () async throws -> String = {
        let result = try await AppTransaction.shared
        guard case .verified = result else { throw JevError.unavailable }
        return result.jwsRepresentation
    }

    func decide(_ decision: JevRequest) async throws -> JevResponse {
        let signedTransaction: String
        do { signedTransaction = try await appTransaction() }
        catch { throw JevError.unavailable }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signedTransaction, forHTTPHeaderField: "X-Interlinked-App-Transaction")
        request.httpBody = try decision.encoded()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw JevError.unavailable }
        switch response.statusCode {
        case 200: break
        case 413: throw JevError.tooLarge
        case 429: throw JevError.rateLimited
        default: throw JevError.unavailable
        }
        guard let result = try? JSONDecoder().decode(JevResponse.self, from: data) else { throw JevError.invalidResponse }
        return try result.validated(for: decision)
    }
}

/// One cancellable service for every decision. No prompt or response logging.
actor JevService {
    private let provider: any JevProvider
    private var cache: JevDecisionCache
    private var pending: [UUID: Task<JevResponse, Error>] = [:]
    private var generation = 0
    private var cooldown = Date.distantPast

    init(provider: any JevProvider = JevRuntime.provider(), cache: JevDecisionCache = JevDecisionCache()) {
        self.provider = provider
        self.cache = cache
    }

    func reset() {
        generation += 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        cooldown = .distantPast
    }

    func clearCache() {
        cache.removeAll()
    }

    func decide(_ request: JevRequest) async throws -> JevResponse {
        try Task.checkCancellation()
        let data = try request.encoded()
        guard !request.questions.isEmpty else { throw JevError.invalidResponse }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let result = cache.value(for: key) { return result }
        guard cooldown < Date() else { throw JevError.rateLimited }
        // Page checks send a few batches at once; leave room for one more feature.
        guard pending.count < PassageDecisions.parallelRequests + 2 else { throw JevError.busy }
        let revision = generation, id = UUID(), provider = provider
        let task = Task { try await provider.decide(request) }
        pending[id] = task
        defer { pending.removeValue(forKey: id) }
        do {
            let response = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            let result = try response.validated(for: request)
            cache.insert(result, for: key)
            return result
        } catch {
            if revision == generation, error as? JevError == .rateLimited { cooldown = Date().addingTimeInterval(60) }
            throw error
        }
    }
}

/// Generation checks also protect against providers that finish after cancellation.
struct RequestRevision {
    private(set) var value = UUID()
    mutating func advance() -> UUID { value = UUID(); return value }
    func accepts(_ token: UUID) -> Bool { value == token }
}
