import Foundation

/// Something the person does in the browser while the Onboarding tab is open.
/// Steps only count in order, so an accidental keypress cannot skip ahead.
enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case openedTab
    case cameBack
    case split
    case closedPane
    /// Next on the Browser Intelligence scene. Both switches are optional.
    case intelligenceNext
    /// Find for me highlighted a match on the demo page.
    case foundWithMeaning
    /// Next on the Sharing Screen Mode and address scene. Both are optional.
    case extrasNext
    /// Start browsing, on the last scene.
    case finished
}

/// Real pages onboarding opens beside itself.
enum OnboardingPage: Sendable {
    /// The demo blog, for Find for me.
    case slowMornings

    var url: URL {
        switch self {
        case .slowMornings: OnboardingDemo.url()
        }
    }

    /// Onboarding's share of the split.
    var onboardingShare: Double {
        switch self {
        case .slowMornings: 0.34
        }
    }
}

/// The page Find for me is shown on: a made-up blog
/// written so it has something to find. Debug builds can point it at a
/// local copy of `docs/try` with the `onboarding.demoURL` default.
enum OnboardingDemo {
    /// Published from the public ojowwalker77/slow-mornings repo. Its source is `docs/try`.
    static let hostedURL = URL(string: "https://ojowwalker77.github.io/slow-mornings/")!

    static func url(defaults: UserDefaults = .standard) -> URL {
        #if DEBUG
        if let raw = defaults.string(forKey: "onboarding.demoURL"), let url = URL(string: raw) { return url }
        #endif
        return hostedURL
    }
}

/// A feature a scene introduces, switched with a real toggle on the page.
/// Every one starts off during onboarding, so turning it on is the lesson.
enum OnboardingFeature: String, Sendable {
    case appleIntelligence
    case jev
    case sharingScreen
    case usefulInfo
    case adBlocking
    case darkPages

    var title: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .jev: "Jev"
        case .sharingScreen: "Sharing Screen Mode"
        case .usefulInfo: "Address & contact"
        case .adBlocking: "Ad blocking"
        case .darkPages: "Dark pages"
        }
    }

    var summary: String {
        switch self {
        case .appleIntelligence: "Runs on your Mac. Nothing leaves it."
        case .jev: "A classifier, not generative AI. Runs in the cloud."
        case .sharingScreen: "Blurs emails, phone numbers, cards and passwords while you share your screen. ⇧⌘S anytime."
        case .usefulInfo: "When a page lists its address or phone, copy it with one click in the sidebar."
        case .adBlocking: "Blocks ads and trackers before they load."
        case .darkPages: "Darkens pages that have no dark theme of their own."
        }
    }

    /// The feature's official mark: an SF Symbol, or an asset in the catalog.
    var mark: (symbol: String?, asset: String?) {
        switch self {
        case .appleIntelligence: ("apple.intelligence", nil)
        case .jev: (nil, "JevMark")
        case .sharingScreen, .usefulInfo, .adBlocking, .darkPages: (nil, nil)
        }
    }
}

/// A piece of an instruction: plain words, or keys drawn as keycaps.
enum OnboardingText: Equatable, Sendable {
    case words(String)
    case keys([String])
}

/// One thing to do: what to say, and the checklist line that ticks when the
/// browser sees it done.
struct OnboardingPart: Equatable, Sendable {
    var step: OnboardingStep
    var instruction: [OnboardingText]
    var check: String
    /// False for a step done away from the page; only the coach shows it.
    var onPage = true
}

struct OnboardingScene: Identifiable, Equatable, Sendable {
    var id: Int
    var title: String?
    var paragraphs: [String] = []
    /// Paragraphs set in small print, like notes and disclaimers.
    var smallPrint = false
    var features: [OnboardingFeature] = []
    /// A real page the scene opens beside itself, where its features act.
    var page: OnboardingPage? = nil
    var parts: [OnboardingPart]
    /// What the coach says when you leave during a step meant for the page.
    var away: [OnboardingText]
    /// `<gif>.gif` in the app bundle. The slot stays empty until it exists.
    var gif: String

    var steps: [OnboardingStep] { parts.map(\.step) }

    /// The part waiting to be done, or the last one once all are.
    func current(_ progress: OnboardingProgress) -> OnboardingPart {
        parts.first { !progress.isDone($0.step) } ?? parts[parts.count - 1]
    }

    /// Parts done so far plus the current one, so each line appears only
    /// when it is the next thing to do.
    func revealed(_ progress: OnboardingProgress) -> [OnboardingPart] {
        let current = current(progress)
        return parts.filter { progress.isDone($0.step) || $0.step == current.step }
    }

    static let all: [OnboardingScene] = [
        OnboardingScene(
            id: 1,
            title: "Welcome to Interlinked!",
            parts: [
                OnboardingPart(step: .openedTab,
                               instruction: [.words("First try creating a new tab with"), .keys(["⌘", "T"])],
                               check: "Opened a new tab"),
                OnboardingPart(step: .cameBack,
                               instruction: [.words("Now press"), .keys(["⌘", "1"]), .words("to come back to the welcome tab!")],
                               check: "Came back here", onPage: false),
            ],
            away: [.words("Press"), .keys(["⌘", "1"]), .words("to go back to the welcome tab and keep going.")],
            gif: "onboarding-scene-1"
        ),
        OnboardingScene(
            id: 2,
            title: nil,
            parts: [
                OnboardingPart(step: .split,
                               instruction: [
                                   .words("You can drag that new tab to split it! Hold left"), .keys(["⌘"]),
                                   .words("or hover the bottom left to see your tabs."),
                               ],
                               check: "Split the window"),
                OnboardingPart(step: .closedPane,
                               instruction: [.words("Afterwards click on that page and press"), .keys(["⌘", "W"]), .words("to close it.")],
                               check: "Closed the other page"),
            ],
            away: [.words("Press"), .keys(["⌘", "1"]), .words("to go back to the welcome tab and keep going.")],
            gif: "onboarding-scene-2"
        ),
        OnboardingScene(
            id: 3,
            title: "Browser Intelligence",
            paragraphs: [
                "We're not building an AI browser. Quietly, it just makes browsing better and safer.",
                "Or skip it and enjoy the sick design!",
            ],
            features: [.appleIntelligence, .jev],
            parts: [
                OnboardingPart(step: .intelligenceNext, instruction: [], check: "Saw Browser Intelligence"),
            ],
            away: [.words("Press"), .keys(["⌘", "1"]), .words("to go back to the welcome tab and keep going.")],
            gif: "onboarding-scene-3"
        ),
        OnboardingScene(
            id: 4,
            title: "Let's try it on a real page",
            page: .slowMornings,
            parts: [
                OnboardingPart(step: .foundWithMeaning,
                               instruction: [
                                   .words("Press"), .keys(["⌘", "F"]),
                                   .words("on the page beside and ask: how long is the warranty?"),
                               ],
                               check: "Found it with Find for me"),
            ],
            away: [.words("Press"), .keys(["⌘", "1"]), .words("to go back to the welcome tab and keep going.")],
            gif: "onboarding-scene-4"
        ),
        OnboardingScene(
            id: 5,
            title: "A couple more handy ones",
            features: [.sharingScreen, .usefulInfo],
            page: .slowMornings,
            parts: [
                OnboardingPart(step: .extrasNext, instruction: [], check: "Saw Sharing Screen Mode and Address & contact"),
            ],
            away: [.words("Press"), .keys(["⌘", "1"]), .words("to go back to the welcome tab and keep going.")],
            gif: "onboarding-scene-5"
        ),
        OnboardingScene(
            id: 6,
            title: "That's it for now!",
            paragraphs: [
                "Interlinked is still pretty experimental. It will keep improving and bring more features for your experience and safety.",
                "AI features will keep coming, always off by default, to help and empower you in this new moment in history. Each one arrives only once we get it right: meaningful, with the right ergonomics and a safe architecture around it.",
                "Jev is free for now. That might change, for example to bringing your own API key, or whatever makes sense later.",
            ],
            smallPrint: true,
            features: [.adBlocking, .darkPages],
            parts: [
                OnboardingPart(step: .finished, instruction: [], check: "Started browsing"),
            ],
            away: [.words("Press"), .keys(["⌘", "1"]), .words("to go back to the welcome tab and finish.")],
            gif: "onboarding-scene-6"
        ),
    ]
}

struct OnboardingProgress: Codable, Equatable, Sendable {
    private(set) var done: [OnboardingStep] = []

    /// The step that counts next, or nil when every step is done.
    var next: OnboardingStep? { OnboardingStep.allCases.first { !done.contains($0) } }

    /// The scene holding the next step. Once everything is done, the last
    /// scene stays until more are added.
    var scene: OnboardingScene {
        OnboardingScene.all.first { scene in scene.steps.contains { !done.contains($0) } } ?? OnboardingScene.all.last!
    }

    func isDone(_ step: OnboardingStep) -> Bool { done.contains(step) }

    /// Records `step` only when it is the one expected next.
    @discardableResult
    mutating func record(_ step: OnboardingStep) -> Bool {
        guard step == next else { return false }
        done.append(step)
        return true
    }
}

extension OnboardingProgress {
    /// A step a later version removed is skipped, so progress saved before
    /// it went still loads instead of starting over.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        done = try container.decode([String].self, forKey: .done).compactMap(OnboardingStep.init(rawValue:))
    }
}

/// What survives a relaunch: where the person got to, and whether they
/// closed onboarding on purpose.
struct OnboardingStore {
    private static let progressKey = "onboarding.progress"
    private static let dismissedKey = "onboarding.dismissed"
    private static let alwaysShowKey = "onboarding.debug.alwaysShow"

    var defaults: UserDefaults = .standard

    var progress: OnboardingProgress {
        get {
            defaults.data(forKey: Self.progressKey)
                .flatMap { try? JSONDecoder().decode(OnboardingProgress.self, from: $0) } ?? OnboardingProgress()
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.progressKey) }
    }

    var dismissed: Bool {
        get { defaults.bool(forKey: Self.dismissedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.dismissedKey) }
    }

    /// Debug builds only: open onboarding at every launch, from the start.
    var alwaysShow: Bool {
        get { defaults.bool(forKey: Self.alwaysShowKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.alwaysShowKey) }
    }

    func reset() {
        defaults.removeObject(forKey: Self.progressKey)
        defaults.removeObject(forKey: Self.dismissedKey)
    }
}
