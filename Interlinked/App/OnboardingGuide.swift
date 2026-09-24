import Foundation
import Observation

/// The Onboarding tab: which pane it lives in, how far the person has got,
/// and the note shown when they try to close it by accident. Progress is
/// kept on this Mac only.
@MainActor @Observable
final class OnboardingGuide {
    private(set) var pane: PaneID?
    /// The page opened beside onboarding for the current scene, if any.
    var sidePane: PaneID?
    private(set) var progress: OnboardingProgress
    /// Shown on the page briefly when ⌘W or a close button aims at it.
    private(set) var notice: String?
    var alwaysShow: Bool {
        didSet { store.alwaysShow = alwaysShow }
    }

    @ObservationIgnored private let store: OnboardingStore
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(store: OnboardingStore = OnboardingStore()) {
        self.store = store
        progress = store.progress
        alwaysShow = store.alwaysShow
    }

    var showsAtLaunch: Bool {
        #if DEBUG
        if alwaysShow { return true }
        #endif
        return !store.dismissed
    }

    func contains(_ pane: PaneID?) -> Bool { pane != nil && pane == self.pane }

    func opened(in pane: PaneID) {
        self.pane = pane
        store.dismissed = false
    }

    func record(_ step: OnboardingStep) {
        guard pane != nil, progress.record(step) else { return }
        store.progress = progress
    }

    func protect() {
        notice = "The welcome tab stays open while you learn. Use Close onboarding at the bottom when you're done."
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Closed on purpose: it will not open at launch again.
    func dismissed() {
        pane = nil
        notice = nil
        store.dismissed = true
    }

    func reset() {
        store.reset()
        progress = OnboardingProgress()
    }
}
