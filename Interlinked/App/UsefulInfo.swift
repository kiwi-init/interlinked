import AppKit
import Observation

/// The page's own address and contact details, found on this Mac when a page
/// loads, and offered as copy buttons above the toolbox.
@MainActor @Observable
final class UsefulInfo {
    var showsAddress: Bool {
        didSet { defaults.set(showsAddress, forKey: UsefulInfoPreference.addressKey); refreshAll() }
    }
    var showsContact: Bool {
        didSet { defaults.set(showsContact, forKey: UsefulInfoPreference.contactKey); refreshAll() }
    }
    private(set) var contacts: [PaneID: PageContacts] = [:]
    /// The value most recently copied, for brief "Copied" feedback.
    private(set) var copied: String?
    /// The contact button has grown into its list of choices.
    var contactOpen = false

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tasks: [PaneID: Task<Void, Never>] = [:]
    @ObservationIgnored private var copiedTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsAddress = UsefulInfoPreference.address(in: defaults)
        showsContact = UsefulInfoPreference.contact(in: defaults)
    }

    var enabled: Bool { showsAddress || showsContact }

    /// What the active page offers, limited to what Settings allows.
    var active: PageContacts? {
        guard let pane = workspace?.activePane, var found = contacts[pane] else { return nil }
        if !showsAddress { found.address = nil }
        if !showsContact { found.phones = []; found.emails = [] }
        return found.isEmpty ? nil : found
    }

    func committed(_ pane: PaneID) {
        if pane == workspace?.activePane { contactOpen = false }
        tasks.removeValue(forKey: pane)?.cancel()
        contacts.removeValue(forKey: pane)
    }

    func loaded(_ pane: PaneID, page: WebKitPage) {
        guard enabled else { return }
        let url = page.url
        tasks[pane]?.cancel()
        tasks[pane] = Task { [weak self, weak page] in
            // Many sites fill their footer and contact blocks after load.
            for delay in [300, 2_500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, let page, page.url == url,
                      let signals = try? await PageTextBridge.contacts(page) else { return }
                let found = await Task.detached(priority: .utility) { PageContactDetector.contacts(from: signals) }.value
                guard !Task.isCancelled, page.url == url else { return }
                self.contacts[pane] = found
                if !found.isEmpty { break }
            }
        }
    }

    func prune(keep alive: (PaneID) -> Bool) {
        for pane in contacts.keys where !alive(pane) { committed(pane) }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = value
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            self?.copied = nil
        }
    }

    private func refreshAll() {
        guard let workspace else { return }
        guard enabled else { contacts.removeAll(); return }
        workspace.hosts.forEachBrowser { page in
            guard let pane = workspace.hosts.pane(of: page), contacts[pane] == nil else { return }
            loaded(pane, page: page)
        }
    }
}
