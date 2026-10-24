import AppKit

/// Control commands for the page tools, panels, Settings, and the window,
/// so the app can be driven and inspected without the pointer. None of
/// these are reachable by voice: `Intent.command` names only tab commands.
extension Control {
    // MARK: - Find and page sharing

    @MainActor
    static func find(_ words: [String], _ workspace: Workspace) -> String {
        let assistant = workspace.assistance
        let text = words.dropFirst().joined(separator: " ")
        switch words.first ?? "state" {
        case "state": break
        case "open":
            // The toolbox button: downloads step aside for the find field.
            workspace.downloads.closePanel()
            assistant.openFind()
            if !text.isEmpty { assistant.query = text; assistant.findChanged() }
        case "query":
            if assistant.panel != .find { workspace.downloads.closePanel(); assistant.openFind() }
            assistant.query = text
            assistant.findChanged()
        case "next": assistant.moveMatch(1)
        case "prev", "previous": assistant.moveMatch(-1)
        case "meaning":
            guard let on = onOff(words.dropFirst().first) else { return error("find meaning takes on or off") }
            assistant.byMeaning = on
            assistant.findChanged()
        case "close":
            if assistant.panel == .find { assistant.closePanel() }
        default:
            return error("find takes state, open [text], query text, next, prev, meaning on|off, or close")
        }
        return json([
            "open": assistant.panel == .find,
            "panel": panelName(assistant.panel),
            "query": assistant.query,
            "by_meaning": assistant.byMeaning,
            "busy": assistant.busy,
            "status": assistant.status,
            "exact_matched": assistant.exactMatched,
            "match_index": assistant.matchIndex,
            "matches": assistant.matches.map { ["id": $0.id, "text": $0.text] },
            "scores": assistant.findScores,
        ])
    }

    @MainActor
    static func sharePage(_ words: [String], _ workspace: Workspace) -> String {
        let assistant = workspace.assistance
        let allowed = assistant.canShare && assistant.enabled && assistant.hasJevAccess
        switch words.first ?? "state" {
        case "state": break
        case "request": assistant.requestSharing()
        case "allow", "remember":
            guard assistant.panel == .permission else { return error("the sharing request is not open. Try: share-page request") }
            guard allowed else { return error("sharing is unavailable here: \(shareBlocker(assistant))") }
            assistant.allowPage(remember: words[0] == "remember")
        case "cancel":
            if assistant.panel == .permission { assistant.closePanel() }
        case "stop", "revoke":
            guard assistant.shared else { return error("this page is not shared") }
            assistant.revokePage()
        default:
            return error("share-page takes state, request, allow, remember, cancel, or stop")
        }
        return json([
            "open": assistant.panel == .permission,
            "origin": assistant.origin,
            "can_share": assistant.canShare,
            "shared": assistant.shared,
            "allowed": allowed,
            "status": assistant.status,
            "granted_origins": assistant.originGrants.records,
        ])
    }

    @MainActor
    private static func shareBlocker(_ assistant: BrowserAssistance) -> String {
        if !assistant.enabled { return "Jev is off" }
        if !assistant.hasJevAccess { return "Jev needs an API key" }
        return "local, editable, and password pages cannot be shared"
    }

    static func panelName(_ panel: BrowserAssistance.Panel?) -> Any {
        switch panel {
        case .find: "find"
        case .permission: "permission"
        case nil: NSNull()
        }
    }

    // MARK: - Page handle panels

    @MainActor
    static func history(_ words: [String], _ workspace: Workspace) -> String {
        let visits = workspace.browserHistory.visits
        switch words.first ?? "state" {
        case "state": break
        case "open": if !workspace.pageHistoryOpen { workspace.togglePageHistory() }
        case "close": workspace.pageHistoryOpen = false
        case "toggle": workspace.togglePageHistory()
        case "visit", "remove", "remove-site":
            guard let index = words.dropFirst().first.flatMap(Int.init), visits.indices.contains(index) else {
                return error("history \(words[0]) takes a visit index from history state")
            }
            switch words[0] {
            case "visit": workspace.openHistoryVisit(visits[index])
            case "remove": workspace.browserHistory.remove(visits[index].id)
            default: workspace.browserHistory.removeSite(visits[index].host)
            }
        case "clear":
            guard let name = words.dropFirst().first else {
                guard workspace.pageHistoryOpen, !visits.isEmpty else { return error("history clear needs the panel open with visits in it") }
                workspace.beginClearingHistory()
                break
            }
            guard let range = HistoryRange(rawValue: name) else {
                return error("history clear takes \(HistoryRange.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            workspace.clearHistory(range)
        default:
            return error("history takes state, open, close, toggle, visit N, remove N, remove-site N, or clear [hour|today|all]")
        }
        let shown = workspace.browserHistory.visits
        return json([
            "open": workspace.pageHistoryOpen,
            "clearing": workspace.historyClearing,
            "enabled": workspace.browserHistory.enabled,
            "count": shown.count,
            "visits": shown.prefix(50).enumerated().map { index, visit in
                ["index": index, "title": visit.title, "host": visit.host, "url": visit.url,
                 "visited": timestamp(visit.visited)] as [String: Any]
            },
        ])
    }

    @MainActor
    static func downloads(_ words: [String], _ workspace: Workspace) -> String {
        let center = workspace.downloads
        switch words.first ?? "state" {
        case "state": break
        case "open": if !center.panelOpen { workspace.toggleDownloads() }
        case "close": center.closePanel()
        case "toggle": workspace.toggleDownloads()
        case "clear": center.clearFinished()
        case "cancel", "reveal":
            guard let record = downloadRecord(words.dropFirst().first, center) else {
                return error("downloads \(words[0]) takes a download index or id from downloads state")
            }
            if words[0] == "cancel" {
                guard record.state.isActive else { return error("that download is not running") }
                center.cancel(record.id)
            } else {
                guard record.canReveal else { return error("that download has no finished file") }
                center.reveal(record.id)
            }
        case "allow-notifications":
            center.requestNotificationPermission()
        default:
            return error("downloads takes state, open, close, toggle, clear, cancel N, reveal N, or allow-notifications")
        }
        return json([
            "open": center.panelOpen,
            "unread": center.unreadCount,
            "active": center.activeCount,
            "notifications": center.notificationStatus,
            "records": center.records.enumerated().map { index, record in
                [
                    "index": index,
                    "id": record.id.uuidString,
                    "filename": record.filename,
                    "origin": record.origin,
                    "state": record.state.rawValue,
                    "fraction": record.fractionCompleted ?? NSNull(),
                    "received": record.receivedBytes,
                    "expected": record.expectedBytes ?? NSNull(),
                    "message": record.message ?? "",
                    "destination": record.destination?.path ?? "",
                ] as [String: Any]
            },
        ])
    }

    @MainActor
    private static func downloadRecord(_ word: String?, _ center: DownloadCenter) -> DownloadRecord? {
        guard let word else { return nil }
        if let index = Int(word) { return center.records.indices.contains(index) ? center.records[index] : nil }
        return center.records.first { $0.id.uuidString.caseInsensitiveCompare(word) == .orderedSame }
    }

    @MainActor
    static func quickSwitch(_ words: [String], _ workspace: Workspace) -> String {
        switch words.first ?? "state" {
        case "state": break
        case "show": workspace.quickSwitchOpen = true
        case "hide": workspace.quickSwitchOpen = false
        case "toggle": workspace.quickSwitchOpen.toggle()
        case "select":
            guard let index = words.dropFirst().first.flatMap(Int.init), workspace.selectQuickTab(index) else {
                return error("quick-switch select takes an index from quick-switch state")
            }
        default:
            return error("quick-switch takes state, show, hide, toggle, or select N")
        }
        return json([
            "open": workspace.quickSwitchOpen,
            "left_command": workspace.leftCommandKeyHeld,
            "right_command": workspace.rightCommandKeyHeld,
            "tabs": workspace.quickTabs.enumerated().map { index, tab in
                ["index": index, "id": Int(tab.id.rawValue), "title": workspace.title(tab),
                 "shortcut": index < 9 ? "⌘\(index + 1)" : ""] as [String: Any]
            },
        ])
    }

    @MainActor
    static func usefulInfo(_ words: [String], _ workspace: Workspace) -> String {
        let info = workspace.usefulInfo
        let shown = info.active
        let options = shown?.options ?? []
        switch words.first ?? "state" {
        case "state": break
        case "copy":
            switch words.dropFirst().first {
            case "address":
                guard let address = shown?.address else { return error("this page shows no address") }
                info.copy(address)
            case "contact":
                guard !options.isEmpty else { return error("this page shows no contact") }
                if let index = words.dropFirst(2).first.flatMap(Int.init) {
                    guard options.indices.contains(index) else { return error("no contact option \(index)") }
                    info.copy(options[index].value)
                } else if options.count == 1 {
                    info.copy(options[0].value)
                } else {
                    // What the button does with several: grow into the choices.
                    info.contactOpen = true
                }
            default:
                return error("useful-info copy takes address, or contact [N]")
            }
        case "contact":
            switch words.dropFirst().first {
            case "open":
                guard options.count > 1 else { return error("the contact button opens only with several options") }
                info.contactOpen = true
            case "close": info.contactOpen = false
            default: return error("useful-info contact takes open or close")
            }
        default:
            return error("useful-info takes state, copy address, copy contact [N], or contact open|close")
        }
        let found = workspace.activePane.flatMap { info.contacts[$0] }
        return json([
            "address_enabled": info.showsAddress,
            "contact_enabled": info.showsContact,
            "address": found?.address ?? "",
            "phones": found?.phones ?? [],
            "emails": found?.emails ?? [],
            "shown": shown != nil && !workspace.overviewOpen,
            "shown_address": shown?.address ?? "",
            "options": options.enumerated().map { index, option in
                ["index": index, "kind": option.kind == .phone ? "phone" : "email", "value": option.value] as [String: Any]
            },
            "contact_open": info.contactOpen,
            "copied": info.copied ?? "",
        ])
    }

    @MainActor
    static func suggestions(_ words: [String], _ workspace: Workspace) -> String {
        let results = workspace.searchResults
        switch words.first ?? "state" {
        case "state": break
        case "next": workspace.moveSearchSelection(1)
        case "prev", "previous": workspace.moveSearchSelection(-1)
        case "submit":
            guard workspace.editing != nil else { return error("no line is being written") }
            workspace.submitLine()
        case "open":
            guard let index = words.dropFirst().first.flatMap(Int.init), results.indices.contains(index) else {
                return error("suggestions open takes an index from suggestions state")
            }
            workspace.openSearchResult(results[index])
        default:
            return error("suggestions takes state, next, prev, submit, or open N")
        }
        return json([
            "selected": workspace.selectedSearchResult.map { $0 as Any } ?? NSNull(),
            "results": workspace.searchResults.enumerated().map { index, result in
                ["index": index, "title": result.title, "url": result.url.absoluteString, "source": result.source.label] as [String: Any]
            },
        ])
    }

    // MARK: - Settings

    @MainActor
    static func settings(_ words: [String], _ workspace: Workspace) -> String {
        switch words.first ?? "state" {
        case "state":
            break
        case "get":
            guard let name = words.dropFirst().first, let setting = ControlSetting(rawValue: name) else {
                return error("settings get takes one of: \(settingNames())")
            }
            return json([setting.rawValue: value(setting, workspace)])
        case "set":
            guard words.count == 3, let setting = ControlSetting(rawValue: words[1]) else {
                return error("settings set takes a name and a value. Names: \(settingNames())")
            }
            guard let parsed = setting.parse(words[2]) else {
                return error("\(setting.rawValue) takes \(setting.choices.joined(separator: " or "))")
            }
            if let refused = set(setting, parsed, workspace) { return error(refused) }
            return json([setting.rawValue: value(setting, workspace)])
        case "open":
            let destination: SettingsDestination
            if let name = words.dropFirst().first {
                guard let named = SettingsDestination.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                    return error("settings open takes \(SettingsDestination.allCases.map { $0.rawValue.lowercased() }.joined(separator: " "))")
                }
                destination = named
            } else {
                destination = .general
            }
            guard workspace.openNativeSettings(destination) else { return error("the browser window has not appeared yet") }
        case "close":
            settingsWindow()?.performClose(nil)
        case "remove-jev-key":
            guard !workspace.assistance.usesIncludedJev else { return error("this build includes Jev and keeps no key") }
            guard workspace.assistance.hasKey else { return error("no key is saved") }
            JevCredential.remove()
            workspace.assistance.configure()
        case "clear-ai-cache":
            workspace.assistance.clearDecisionCache()
        case "update-lists":
            guard !workspace.builtIns.updating else { return error("the filter lists are already updating") }
            Task { await workspace.builtIns.updateLists() }
        default:
            return error("settings takes state, get NAME, set NAME VALUE, open [pane], close, remove-jev-key, clear-ai-cache, or update-lists")
        }
        let assistant = workspace.assistance
        let builtIns = workspace.builtIns
        let window = settingsWindow()
        return json([
            "window": window.map(describe) ?? NSNull(),
            "destination": workspace.settingsDestination.rawValue.lowercased(),
            "values": Dictionary(uniqueKeysWithValues: ControlSetting.allCases.map { ($0.rawValue, value($0, workspace)) }),
            "choices": Dictionary(uniqueKeysWithValues: ControlSetting.allCases.map { ($0.rawValue, $0.choices) }),
            "jev_included": assistant.usesIncludedJev,
            "jev_key_saved": assistant.hasKey,
            "apple_intelligence_available": LocalIntelligenceRuntime.isAvailable,
            "ai_cache": assistant.cacheStatus,
            "notifications": workspace.downloads.notificationStatus,
            "lists_ready": builtIns.engineReady,
            "lists_updating": builtIns.updating,
            "lists_updated": builtIns.listsUpdatedAt.map(timestamp) ?? NSNull(),
            "lists_status": builtIns.status,
            "activity_count": workspace.intelligenceAudit.events.count,
        ])
    }

    private static func settingNames() -> String {
        ControlSetting.allCases.map(\.rawValue).joined(separator: " ")
    }

    @MainActor
    static func value(_ setting: ControlSetting, _ workspace: Workspace) -> Any {
        let assistant = workspace.assistance
        switch setting {
        case .usefulAddress: return workspace.usefulInfo.showsAddress
        case .usefulContact: return workspace.usefulInfo.showsContact
        case .blocking: return workspace.builtIns.blockingEnabled
        case .darkPages: return workspace.builtIns.darkMode.rawValue
        case .jev: return assistant.enabled
        case .appleIntelligence: return workspace.binding(for: .appleIntelligence).wrappedValue
        case .refineLabels: return assistant.automaticLabels
        case .sharingScreenMode: return workspace.sharingScreenMode
        case .browsingHistory: return workspace.browserHistory.enabled
        case .onboardingAlwaysShow: return workspace.onboarding.alwaysShow
        case .searchProvider: return workspace.search.provider.rawValue
        case .remoteSuggestions: return workspace.search.remoteSuggestions
        case .suggestionProvider: return workspace.search.suggestionOverride?.rawValue ?? ControlSetting.sameAsSearch
        }
    }

    /// Changes a setting the way its control in Settings does. Returns why
    /// it could not.
    @MainActor
    static func set(_ setting: ControlSetting, _ value: ControlSetting.Value, _ workspace: Workspace) -> String? {
        let assistant = workspace.assistance
        switch (setting, value) {
        case (.usefulAddress, .bool(let on)): workspace.usefulInfo.showsAddress = on
        case (.usefulContact, .bool(let on)): workspace.usefulInfo.showsContact = on
        case (.blocking, .bool(let on)): workspace.builtIns.blockingEnabled = on
        case (.darkPages, .choice(let raw)):
            guard let mode = PageDarkMode(rawValue: raw) else { return "no dark mode \(raw)" }
            workspace.builtIns.darkMode = mode
        case (.jev, .bool(let on)):
            assistant.enabled = on
            assistant.configure()
        case (.appleIntelligence, .bool(let on)):
            // In Settings the switch opens System Settings instead.
            if on && !LocalIntelligenceRuntime.isAvailable { return "Apple Intelligence is off on this Mac" }
            workspace.binding(for: .appleIntelligence).wrappedValue = on
        case (.refineLabels, .bool(let on)):
            guard assistant.appleEnabled else { return "refine-labels needs apple-intelligence on" }
            assistant.automaticLabels = on
            assistant.configure()
        case (.sharingScreenMode, .bool(let on)): workspace.sharingScreenMode = on
        case (.browsingHistory, .bool(let on)): workspace.browserHistory.enabled = on
        case (.onboardingAlwaysShow, .bool(let on)): workspace.onboarding.alwaysShow = on
        case (.searchProvider, .choice(let raw)):
            guard let provider = SearchProvider(rawValue: raw) else { return "no search provider \(raw)" }
            workspace.search.provider = provider
        case (.remoteSuggestions, .bool(let on)): workspace.search.remoteSuggestions = on
        case (.suggestionProvider, .choice(let raw)):
            workspace.search.suggestionOverride = SearchProvider(rawValue: raw)
        default: return "\(setting.rawValue) takes \(setting.choices.joined(separator: " or "))"
        }
        return nil
    }

    @MainActor
    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
    }

    @MainActor
    static func sites(_ words: [String], _ workspace: Workspace) -> String {
        let grants = workspace.assistance.originGrants
        let permissions = workspace.permissions
        let exceptions = workspace.navigationExceptions
        let builtIns = workspace.builtIns
        func named(_ origin: String, _ site: String) -> Bool {
            origin == site || URL(string: origin)?.host == site
        }
        switch words.first ?? "state" {
        case "state": break
        case "remove", "remove-all":
            let all = words[0] == "remove-all"
            guard let group = words.dropFirst().first, all || words.count >= 3 else {
                return error("sites \(words[0]) takes jev|permissions|unblocked|light|exceptions\(all ? "" : " and a site")")
            }
            let site = all ? nil : words[2]
            var removed = 0
            switch group {
            case "jev":
                for origin in grants.records where site.map({ named(origin, $0) }) ?? true { workspace.assistance.revokeOrigin(origin); removed += 1 }
            case "permissions":
                let kind = words.dropFirst(3).first
                for record in permissions.records where site.map({ named(record.key.origin, $0) }) ?? true
                    && (kind == nil || record.key.kind.rawValue == kind) {
                    permissions.revoke(record.key); removed += 1
                }
            case "unblocked":
                for entry in builtIns.unblockedSites where site.map({ entry == $0 }) ?? true { builtIns.removeUnblockedSite(entry); removed += 1 }
            case "light":
                for entry in builtIns.lightSites where site.map({ entry == $0 }) ?? true { builtIns.removeLightSite(entry); removed += 1 }
            case "exceptions":
                for record in exceptions.records where site.map({ named(record.key.origin, $0) }) ?? true { exceptions.revoke(record.key); removed += 1 }
            default:
                return error("no site group '\(group)'. Try: jev permissions unblocked light exceptions")
            }
            guard removed > 0 else { return error("nothing saved for \(site ?? group)") }
        default:
            return error("sites takes state, remove GROUP SITE [KIND], or remove-all GROUP")
        }
        return json([
            "jev": grants.records.map { ["origin": $0, "remembered": grants.isRemembered($0)] as [String: Any] },
            "permissions": permissions.records.map {
                ["origin": $0.key.origin, "kind": $0.key.kind.rawValue, "decision": $0.decision.rawValue]
            },
            "unblocked": builtIns.unblockedSites.sorted(),
            "light": builtIns.lightSites.sorted(),
            "exceptions": exceptions.records.map { ["origin": $0.key.origin, "reasons": $0.key.reasons] as [String: Any] },
        ])
    }

    @MainActor
    static func activity(_ words: [String], _ workspace: Workspace) -> String {
        let audit = workspace.intelligenceAudit
        switch words.first ?? "state" {
        case "state": break
        case "export":
            guard words.count >= 2 else { return error("activity export takes a file path") }
            let path = (words.dropFirst().joined(separator: " ") as NSString).expandingTildeInPath
            do { try audit.export(to: URL(fileURLWithPath: path)) } catch { return Control.error("could not export: \(error.localizedDescription)") }
        case "clear": audit.clear()
        default: return error("activity takes state, export PATH, or clear")
        }
        return json([
            "count": audit.events.count,
            "recent": audit.recent.map {
                ["action": $0.action, "source": $0.source.rawValue, "outcome": $0.outcome.rawValue,
                 "started": timestamp($0.startedAt)] as [String: Any]
            },
        ])
    }

    // MARK: - Window, focus, and keys

    /// The key window, what has focus in it, and whether text input is
    /// mid-composition, for checking where keys will land.
    @MainActor
    static func windows(_ workspace: Workspace) -> [String: Any] {
        let responder = NSApp.keyWindow?.firstResponder
        var focus: [String: Any] = ["class": responder.map { NSStringFromClass(type(of: $0)) } ?? NSNull()]
        if let input = responder as? NSTextInputClient {
            focus["has_marked_text"] = input.hasMarkedText()
            let marked = input.markedRange()
            focus["marked_range"] = marked.location == NSNotFound ? NSNull() : [marked.location, marked.length]
        } else {
            focus["has_marked_text"] = false
        }
        if let text = responder as? NSTextView {
            focus["field_editor"] = text.isFieldEditor
            let owner = text.delegate as? NSView
            focus["field"] = owner?.accessibilityIdentifier() ?? ""
        }
        if let view = responder as? NSView {
            let pane = workspace.tabs.flatMap(\.panes).first { pane in
                guard let page = workspace.hosts.existingBrowser(pane)?.nativeView else { return false }
                return view === page || view.isDescendant(of: page)
            }
            focus["pane"] = pane.map { Int($0.rawValue) } ?? NSNull()
        }
        return [
            "active": NSApp.isActive,
            "key": NSApp.keyWindow.map(describe) ?? NSNull(),
            "main": NSApp.mainWindow.map(describe) ?? NSNull(),
            "modal": NSApp.modalWindow.map(describe) ?? NSNull(),
            "first_responder": focus,
            "windows": NSApp.windows.filter(\.isVisible).map(describe),
        ]
    }

    @MainActor
    static func describe(_ window: NSWindow) -> [String: Any] {
        let workspace = Workspace.shared
        return [
            "number": window.windowNumber,
            "title": window.title,
            "identifier": window.identifier?.rawValue ?? "",
            "role": window === workspace?.browserWindow ? "browser" : window === settingsWindow() ? "settings" : "other",
            "key": window.isKeyWindow,
            "visible": window.isVisible,
            "sheet": window.sheetParent != nil,
            "frame": [window.frame.origin.x, window.frame.origin.y, window.frame.width, window.frame.height],
        ]
    }

    /// Posts a key press through AppKit, so it meets the same monitors,
    /// menu shortcuts, and first responder a typed key does.
    @MainActor
    static func key(_ words: [String], _ workspace: Workspace) -> String {
        var words = words
        var target = "browser"
        if words.count >= 3, words[words.count - 2] == "to" {
            target = words.removeLast()
            words.removeLast()
        }
        guard let key = ControlKey.parse(words) else {
            return error("key takes a key name, character, or key code, then modifiers, like: key escape, key f cmd, key cmd+shift+g [to browser|key|settings]")
        }
        let window: NSWindow?
        switch target {
        case "browser": window = workspace.browserWindow
        case "key": window = NSApp.keyWindow
        case "settings": window = settingsWindow()
        default: return error("key sends to browser, key, or settings")
        }
        guard let window else { return error("no \(target) window") }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                isARepeat: false, keyCode: key.keyCode
            ) else { return error("could not make that key event") }
            NSApp.postEvent(event, atStart: false)
        }
        return ok()
    }

    // MARK: - Helpers

    /// What the overview's search field matches, as `WorkspaceOverview` does.
    @MainActor
    static func overviewMatches(_ query: String, _ tab: Tab, _ workspace: Workspace) -> Bool {
        OpenWork.matches(query, title: workspace.title(tab), details: tab.root.leaves().flatMap {
            [workspace.surfaces.line($0), workspace.hosts.titles[$0] ?? ""]
        })
    }

    static func onOff(_ word: String?) -> Bool? {
        switch word {
        case "on": true
        case "off": false
        default: nil
        }
    }

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
