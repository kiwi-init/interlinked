import Foundation

enum BrowserRecoveryCause: String, Equatable {
    case memoryPressure
    case webContentTerminated

    var title: String {
        switch self {
        case .memoryPressure: return "This tab was paused"
        case .webContentTerminated: return "This page stopped responding"
        }
    }

    var message: String {
        switch self {
        case .memoryPressure:
            return "Interlinked freed this background tab after macOS reported memory pressure. Restore it when you need it."
        case .webContentTerminated:
            return "The website process ended. Reload the page to continue."
        }
    }

    var action: String {
        switch self {
        case .memoryPressure: return "Restore Page"
        case .webContentTerminated: return "Reload Page"
        }
    }
}

struct BrowserRecovery: Equatable {
    var cause: BrowserRecoveryCause
    var url: URL
    var scrollY: Double
    var occurredAt: Date
}

struct BrowserDiscardProbe: Decodable, Equatable {
    var safe: Bool
    var scrollY: Double

    static let script = #"""
    (() => {
      const media = Array.from(document.querySelectorAll('audio,video'))
        .some(element => !element.paused && !element.ended);
      const inputs = Array.from(document.querySelectorAll('input')).some(input => {
        if (['button','submit','reset','hidden'].includes(input.type)) return false;
        if (input.type === 'file') return input.files && input.files.length > 0;
        if (input.type === 'checkbox' || input.type === 'radio') return input.checked !== input.defaultChecked;
        return input.value !== input.defaultValue;
      });
      const textareas = Array.from(document.querySelectorAll('textarea'))
        .some(input => input.value !== input.defaultValue);
      const selects = Array.from(document.querySelectorAll('select'))
        .some(select => Array.from(select.options).some(option => option.selected !== option.defaultSelected));
      const editable = Array.from(document.querySelectorAll('[contenteditable="true"],[contenteditable=""]'))
        .some(element => element.textContent.trim().length > 0);
      return JSON.stringify({safe: !(media || inputs || textareas || selects || editable), scrollY: window.scrollY});
    })()
    """#

    static func decode(_ value: Any?) -> Self? {
        guard let json = value as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct TabLifecycleLedger {
    private(set) var lastUsed: [PaneID: Date] = [:]
    private(set) var recoveries: [PaneID: BrowserRecovery] = [:]

    var panes: Set<PaneID> { Set(lastUsed.keys).union(recoveries.keys) }

    mutating func register(_ pane: PaneID, at date: Date = Date()) {
        if lastUsed[pane] == nil { lastUsed[pane] = date }
    }

    mutating func touch(_ pane: PaneID, at date: Date = Date()) {
        lastUsed[pane] = date
    }

    mutating func suspend(_ pane: PaneID, recovery: BrowserRecovery) {
        register(pane, at: recovery.occurredAt)
        recoveries[pane] = recovery
    }

    mutating func takeRecovery(_ pane: PaneID, at date: Date = Date()) -> BrowserRecovery? {
        touch(pane, at: date)
        return recoveries.removeValue(forKey: pane)
    }

    mutating func close(_ pane: PaneID) {
        lastUsed.removeValue(forKey: pane)
        recoveries.removeValue(forKey: pane)
    }

    mutating func retain(where keep: (PaneID) -> Bool) {
        for pane in panes where !keep(pane) { close(pane) }
    }
}

enum TabMemoryPressure: Equatable {
    case warning
    case critical
}

struct TabDiscardProtection: OptionSet, Equatable {
    let rawValue: UInt8

    static let active = Self(rawValue: 1 << 0)
    static let media = Self(rawValue: 1 << 1)
    static let upload = Self(rawValue: 1 << 2)
    static let download = Self(rawValue: 1 << 3)
    static let unsavedForm = Self(rawValue: 1 << 4)
}

struct TabMemoryCandidate: Equatable {
    var pane: PaneID
    var lastUsed: Date
    var protections: TabDiscardProtection = []
}

enum TabMemoryPolicy {
    static func discardCount(liveCount: Int, pressure: TabMemoryPressure) -> Int {
        guard liveCount > 0 else { return 0 }
        let retained: Int
        switch pressure {
        case .warning:
            retained = max(8, Int(ceil(Double(liveCount) * 0.75)))
        case .critical:
            retained = max(3, Int(ceil(Double(liveCount) * 0.40)))
        }
        return max(0, liveCount - retained)
    }

    static func orderedDiscardCandidates(_ candidates: [TabMemoryCandidate]) -> [PaneID] {
        candidates
            .filter { $0.protections.isEmpty }
            .sorted {
                if $0.lastUsed == $1.lastUsed { return $0.pane.rawValue < $1.pane.rawValue }
                return $0.lastUsed < $1.lastUsed
            }
            .map(\.pane)
    }
}

/// What a page's own navigation means for everything learned about it.
struct PageNavigationEffects: OptionSet, Equatable {
    let rawValue: UInt8

    /// A new document replaced the old one: metadata, labels, sharing, and
    /// open page panels belong to a page that is gone.
    static let newDocument = Self(rawValue: 1 << 0)
    /// The address moved: the line, favicon, and history follow it.
    static let newAddress = Self(rawValue: 1 << 1)

    /// A route change inside a loaded document (pushState, replaceState, an
    /// #anchor) keeps the page's state but not what it shows, so its label
    /// and contact details are read again. A page still loading is read
    /// once it finishes.
    func rereadsPage(loading: Bool) -> Bool {
        contains(.newAddress) && !contains(.newDocument) && !loading
    }
}

/// WebKit reports pushState and #fragment navigations as an address change
/// with no commit and no finished load. Only a commit replaces the document,
/// so only a commit may reset the page's state.
struct PageNavigationTracker {
    private(set) var url: URL?

    mutating func addressChanged(to url: URL?) -> PageNavigationEffects {
        guard url != self.url else { return [] }
        self.url = url
        return .newAddress
    }

    mutating func committed(to url: URL?) -> PageNavigationEffects {
        addressChanged(to: url).union(.newDocument)
    }
}
