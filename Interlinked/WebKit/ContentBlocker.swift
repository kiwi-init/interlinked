import Foundation
import WebKit

/// One built blocker engine. Brave's engine is immutable once built, so any
/// thread may use it.
final class BlockerEngine: @unchecked Sendable {
    fileprivate let pointer: OpaquePointer

    private init?(_ pointer: OpaquePointer?) {
        guard let pointer else { return nil }
        self.pointer = pointer
    }

    deinit { il_blocker_free(pointer) }

    /// Builds the engine and WebKit's network rules from filter lists in
    /// uBlock Origin syntax. Lists at `trusted` may use response-rewriting
    /// scriptlets. Slow; call off the main thread. `serialized` restores the
    /// engine with `restore(_:resourcesJSON:)`; each of `ruleLists` is one
    /// WebKit content rule list.
    static func build(lists: [String], trusted: IndexSet, resourcesJSON: String)
        -> (engine: BlockerEngine, serialized: Data, ruleLists: [String])? {
        let filters = il_filters_new(false), ruleFilters = il_filters_new(true)
        for (index, list) in lists.enumerated() {
            il_filters_add(filters, list, trusted.contains(index))
            il_filters_add(ruleFilters, list, trusted.contains(index))
        }
        let ruleLists = take(il_filters_content_rules(ruleFilters))?.split(separator: "\n").map(String.init) ?? []
        guard let engine = BlockerEngine(il_blocker_new(filters, resourcesJSON)) else { return nil }
        var length = 0
        guard let bytes = il_blocker_serialize(engine.pointer, &length) else { return nil }
        let serialized = Data(bytes: bytes, count: length)
        il_bytes_free(bytes, length)
        return (engine, serialized, ruleLists)
    }

    static func restore(_ data: Data, resourcesJSON: String) -> BlockerEngine? {
        data.withUnsafeBytes { bytes in
            BlockerEngine(il_blocker_restore(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, resourcesJSON))
        }
    }

    /// The page's element hiding, procedural rules, and scriptlets.
    func cosmetics(for url: String) -> [String: Any]? {
        guard let json = Self.take(il_blocker_cosmetics(pointer, url)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// `query` holds classes, ids, and exceptions; the answer is the generic
    /// hiding rules that apply to them.
    func genericSelectors(_ query: [String: Any]) -> [String] {
        guard let data = try? JSONSerialization.data(withJSONObject: query),
              let json = Self.take(il_blocker_generic_selectors(pointer, String(decoding: data, as: UTF8.self))) else { return [] }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String] ?? []
    }

    /// The address to load instead when a list removes parameters from it.
    func rewrite(_ url: String, source: String, type: String) -> String? {
        var detail: UnsafeMutablePointer<CChar>?
        let verdict = il_blocker_check(pointer, url, source, type, "GET", &detail)
        let value = Self.take(detail)
        return Int(verdict) == IL_REWRITE ? value : nil
    }

    fileprivate static func take(_ value: UnsafeMutablePointer<CChar>?) -> String? {
        guard let value else { return nil }
        defer { il_string_free(value) }
        return String(cString: value)
    }
}

/// The built-in ad and tracker blocker. WebKit applies the network rules
/// itself, from compiled content rule lists; the engine supplies each
/// document's element hiding and scriptlets, and the parameters to strip from
/// page addresses.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()
    /// Element hiding runs in this world, which the page cannot see.
    static let cosmeticsWorld = WKContentWorld.world(name: "interlinked-cosmetics")
    static let cosmeticsHandler = "interlinkedCosmetics"
    private static let cosmeticsBinding = "__interlinkedCosmetics"

    /// Runs in the cosmetics world at document start; blocker-cosmetics.js
    /// explains the `cfg` the caller defines first.
    private static let cosmeticsScript: String = Bundle.main.url(forResource: "blocker-cosmetics", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    private var engine: BlockerEngine?
    private(set) var ruleLists: [WKContentRuleList] = []
    private var enabled = false
    /// Hosts without a leading "www." whose pages load unfiltered.
    private var disabledSites: Set<String> = []

    func install(_ engine: BlockerEngine) { self.engine = engine }

    func setEnabled(_ enabled: Bool, disabledSites: [String]) {
        self.enabled = enabled
        self.disabledSites = Set(disabledSites.map { $0.lowercased() })
    }

    /// Whether pages at `url` are filtered.
    func blocks(_ url: URL?) -> Bool {
        guard enabled else { return false }
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return true }
        return !disabledSites.contains(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }

    func ruleLists(for url: URL?) -> [WKContentRuleList] { blocks(url) ? ruleLists : [] }

    /// Compiles `lists` with WebKit, which keeps them for later launches.
    /// Each compile is a new generation, so one that fails part way leaves
    /// the previous lists whole.
    func compile(_ lists: [String]) async -> Bool {
        guard let store = WKContentRuleListStore.default() else { return false }
        let generation = UInt64(Date().timeIntervalSince1970 * 1000)
        var compiled: [WKContentRuleList] = []
        for (index, list) in lists.enumerated() {
            let identifier = StoredRuleList(generation: generation, index: index, count: lists.count).identifier
            guard let ruleList = try? await store.compileContentRuleList(forIdentifier: identifier,
                                                                         encodedContentRuleList: list) else {
                await remove(from: store) { $0.generation == generation }
                return false
            }
            compiled.append(ruleList)
        }
        await remove(from: store) { $0.generation != generation }
        ruleLists = compiled
        return true
    }

    /// The newest complete generation compiled at an earlier launch.
    func restoreRuleLists() async -> Bool {
        guard let store = WKContentRuleListStore.default() else { return false }
        let stored = await storedRuleLists(store)
        newest: for generation in Set(stored.map(\.generation)).sorted(by: >) {
            let lists = stored.filter { $0.generation == generation }.sorted { $0.index < $1.index }
            guard let count = lists.first?.count, lists.map(\.index) == Array(0..<count) else { continue }
            var restored: [WKContentRuleList] = []
            for list in lists {
                guard let ruleList = try? await store.contentRuleList(forIdentifier: list.identifier) else { continue newest }
                restored.append(ruleList)
            }
            ruleLists = restored
            return true
        }
        return false
    }

    private func storedRuleLists(_ store: WKContentRuleListStore) async -> [StoredRuleList] {
        (await store.availableIdentifiers() ?? []).compactMap(StoredRuleList.init)
    }

    /// Removes the lists `matches` picks, and any in an earlier format.
    private func remove(from store: WKContentRuleListStore, where matches: (StoredRuleList) -> Bool) async {
        for identifier in await store.availableIdentifiers() ?? [] where identifier.hasPrefix(StoredRuleList.prefix) {
            if let list = StoredRuleList(identifier), !matches(list) { continue }
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    /// What the document at `url` needs: scriptlets in the page's world, and
    /// element hiding in a world the page cannot see.
    func documentBlocking(for url: URL) -> DocumentBlocking? {
        guard blocks(url), let engine, let host = url.host?.lowercased(), !host.isEmpty,
              let cosmetics = engine.cosmetics(for: url.absoluteString) else { return nil }
        // Subframes from other sites get neither: the rules were chosen for this site.
        let guardSource = "const h=\(Self.literal(host)),l=location.hostname;if(l!==h&&!l.endsWith('.'+h)&&!h.endsWith('.'+l))return;"
        var scripts: [WKUserScript] = []
        if let scriptlets = cosmetics["script"] as? String, !scriptlets.isEmpty {
            // uBlock Origin's injector gives its scriptlets a shared
            // |scriptletGlobals| object; without it they throw a ReferenceError
            // on first use.
            scripts.append(WKUserScript(source: "(()=>{\(guardSource)const scriptletGlobals={};\n\(scriptlets)\n})();",
                                        injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        let configuration: [String: Any] = [
            "hide": cosmetics["hide"] ?? [],
            "procedural": cosmetics["procedural"] ?? [],
            "generic": !(cosmetics["generichide"] as? Bool ?? false),
            "binding": Self.cosmeticsBinding,
        ]
        let configurationJSON = (try? JSONSerialization.data(withJSONObject: configuration)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // The page reports the class names and ids it uses and is answered with
        // the generic hiding rules for them.
        let binding = "globalThis.\(Self.cosmeticsBinding)=p=>webkit.messageHandlers.\(Self.cosmeticsHandler).postMessage(p)"
            + ".then(s=>s&&s.length&&globalThis.__interlinkedHide?.(s),()=>{});"
        scripts.append(WKUserScript(source: "(()=>{\(guardSource)const cfg=\(configurationJSON);\(binding)\(Self.cosmeticsScript)})();",
                                    injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.cosmeticsWorld))
        return DocumentBlocking(host: host, scripts: scripts, exceptions: cosmetics["exceptions"] as? [String] ?? [])
    }

    /// The generic hiding rules for the class names and ids in `payload`, a
    /// JSON object the cosmetics script sent from a page at `pageURL`.
    func genericSelectors(payload: String, pageURL: URL?, exceptions: [String]) -> [String] {
        guard blocks(pageURL), let engine, payload.utf8.count <= 2_000_000,
              let names = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return [] }
        return engine.genericSelectors([
            "classes": names["classes"] as? [String] ?? [],
            "ids": names["ids"] as? [String] ?? [],
            "exceptions": exceptions,
        ])
    }

    /// `url` without tracking parameters, or nil when it has none. Filtered
    /// pages also lose the parameters the lists name. A subframe's rules
    /// follow the page around it, `page`.
    func cleanAddress(_ url: URL, page: URL?, subframe: Bool) -> URL? {
        var address = url.absoluteString
        if let stripped = BlockerEngine.take(il_strip_tracking(address)) { address = stripped }
        let pageAddress = subframe ? page?.absoluteString ?? address : address
        if blocks(URL(string: pageAddress)), let engine,
           let rewritten = engine.rewrite(address, source: pageAddress, type: subframe ? "subdocument" : "document") {
            address = rewritten
        }
        return address == url.absoluteString ? nil : URL(string: address)
    }

    private static func literal(_ value: String) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

/// One compiled list in WebKit's store: `interlinked-blocker-<generation>-<index>-<count>`.
struct StoredRuleList: Equatable {
    static let prefix = "interlinked-blocker-"
    let generation: UInt64
    let index: Int
    let count: Int

    init(generation: UInt64, index: Int, count: Int) {
        self.generation = generation
        self.index = index
        self.count = count
    }

    init?(_ identifier: String) {
        guard identifier.hasPrefix(Self.prefix) else { return nil }
        let parts = identifier.dropFirst(Self.prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let generation = UInt64(parts[0]), let index = Int(parts[1]), let count = Int(parts[2]),
              index >= 0, index < count else { return nil }
        self.init(generation: generation, index: index, count: count)
    }

    var identifier: String { "\(Self.prefix)\(generation)-\(index)-\(count)" }
}

/// The blocking scripts registered for one document and what the cosmetics
/// world needs to answer it.
struct DocumentBlocking {
    let host: String
    let scripts: [WKUserScript]
    let exceptions: [String]
}
