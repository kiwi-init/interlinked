import Darwin
import Foundation
import AppKit

enum Control {
    static let writeCommands = [
        "new-tab [kind]",
        "open-url URL",
        "sharing-mode on|off|state|check",
        "split-view on|off|other|ratio N|drop TAB left|right|state",
        "onboarding open|close|reset|state",
        "kind kind [pane]",
        "close-tab [page]",
        "focus pane",
        "focus-tab index",
        "next-tab",
        "prev-tab",
        "move-tab tab slot",
        "clear [pane]",
        "listen [command|stop]",
        "dictate sentence",
        "edit [pane]",
        "type text",
        "commit",
        "discard",
        "hear sentence",
        "name-tab [index] name",
        "clear-tab [index]",
        "tint [name]",
        "sidebar [width|collapse|expand|toggle]",
        "overview [show|hide|toggle]",
        "identity [show|hide|toggle]",
        "page-icons [show|hide|toggle]",
        "builtins [state|blocking on|off|dark off|system|always]",
        "site-menu [state|search|close|home|enable|disable|page|more|item ID|submit QUERY|restore]",
        "new-page",
        "new-page-beside",
        "reopen-closed-tab",
        "navigate ADDRESS",
        "open-address ADDRESS",
        "back [pane]",
        "forward [pane]",
        "reload",
        "recover [pane]",
        "copy-url",
        "click pane",
        "escape",
        "key KEY [MODS] [to browser|key|settings]",
        "edit-tab [index]",
        "close-whole-tab [index]",
        "overview search QUERY|submit QUERY",
        "suggestions [state|next|prev|submit|open N]",
        "find [state|open [text]|query text|next|prev|meaning on|off|close]",
        "share-page [state|request|allow|remember|cancel|stop]",
        "history [state|open|close|toggle|visit N|remove N|remove-site N|clear [hour|today|all]]",
        "downloads [state|open|close|toggle|clear|cancel N|reveal N|allow-notifications]",
        "quick-switch [state|show|hide|toggle|select N]",
        "useful-info [state|copy address|copy contact [N]|contact open|close]",
        "onboarding step STEP|feature FEATURE on|off",
        "settings [state|get NAME|set NAME VALUE|open [pane]|close|remove-jev-key|clear-ai-cache|update-lists]",
        "sites [state|remove GROUP SITE [KIND]|remove-all GROUP]",
        "activity [state|export PATH|clear]",
        "quit",
    ]

    static let readCommands = [
        "state",
        "commands",
        "engine-state",
        "assistance-state",
        "identity",
        "measure-frames [pane]",
        "site-menu",
        "useful-info",
        "find",
        "share-page",
        "history",
        "downloads",
        "quick-switch",
        "suggestions",
        "settings",
        "sites",
        "activity",
        "windows",
    ]

    static let maxRequestBytes = 64 * 1024
    static let receiveTimeoutSeconds = 5

    static func socketPath() -> String {
        if let named = ProcessInfo.processInfo.environment["INTERLINKED_SOCKET"], !named.isEmpty {
            return named
        }
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent("Interlinked/control/control.sock").path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Library/Application Support/Interlinked/control/control.sock")
    }

    @MainActor
    static func dispatch(_ request: String, workspace: Workspace) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = words.first else { return error("no command") }
        words.removeFirst()

        switch command {
        case "commands":
            return json([
                "reads": readCommands,
                "writes": writeCommands,
            ])

        case "state":
            return json(snapshot(workspace))

        case "windows":
            return json(windows(workspace))

        case "key":
            return key(words, workspace)

        case "escape":
            workspace.escape()
            return ok()

        case "find": return find(words, workspace)
        case "share-page": return sharePage(words, workspace)
        case "history": return history(words, workspace)
        case "downloads": return downloads(words, workspace)
        case "quick-switch": return quickSwitch(words, workspace)
        case "useful-info": return usefulInfo(words, workspace)
        case "suggestions": return suggestions(words, workspace)
        case "settings": return settings(words, workspace)
        case "sites": return sites(words, workspace)
        case "activity": return activity(words, workspace)

        case "new-page":
            workspace.newPage()
            return ok()

        case "new-page-beside":
            workspace.newPageBeside()
            return ok()

        case "reopen-closed-tab":
            guard !workspace.recentlyClosed.isEmpty else { return error("no closed tab to reopen") }
            workspace.reopenClosedTab()
            return ok()

        case "navigate", "open-address":
            let address = words.joined(separator: " ")
            guard !address.isEmpty else { return error("\(command) needs an address") }
            command == "navigate" ? workspace.navigateActive(address) : workspace.openAddress(address)
            return ok()

        case "back", "forward":
            return withPane(workspace, words.first) { pane in
                guard let page = workspace.hosts.existingBrowser(pane) else { return error("no loaded web page") }
                let able = command == "back" ? workspace.hosts.canGoBack[pane, default: false] : workspace.hosts.canGoForward[pane, default: false]
                guard able else { return error("nothing to go \(command) to") }
                workspace.discardLine()
                command == "back" ? page.goBack() : page.goForward()
                return ok()
            }

        case "reload":
            workspace.reloadActivePage()
            return ok()

        case "recover":
            return withPane(workspace, words.first) { pane in
                guard workspace.hosts.recovery(for: pane) != nil else { return error("that page is not waiting to recover") }
                workspace.recoverPane(pane)
                return ok()
            }

        case "copy-url":
            return workspace.copyCurrentPageURL() ? ok() : error("no web page to copy")

        case "click":
            return withPane(workspace, words.first) { pane in
                guard workspace.paneAlive(pane) else { return error("no pane with that id") }
                workspace.clickPane(pane)
                return ok()
            }

        case "edit-tab", "close-whole-tab":
            return withTab(workspace, words.first) { tab in
                if command == "edit-tab" {
                    workspace.editTab(tab.id)
                } else {
                    workspace.closeTab(tab.id)
                }
                return ok()
            }

        case "engine-state":
            return json([
                "engine": WebKitPage.engineVersion,
                "running": true,
                "application_class": NSStringFromClass(type(of: NSApp)),
                "active_pages": workspace.tabs.filter { workspace.hosts.existingBrowser($0.active) != nil }.count,
            ])

        case "site-menu":
            switch words.first {
            case "search": workspace.beginSiteMenuSearch()
            case "close": workspace.collapseSiteMenuChrome()
            case "home": workspace.goSiteHome()
            case "page":
                // Writes what the page shows at the top, to check for a doubled header.
                guard let view = workspace.activePane.flatMap(workspace.hosts.existingBrowser) else { return error("no loaded web page") }
                Task { @MainActor in
                    let report = try? await view.evaluateJavaScript("""
                    (() => {
                      const hidden = [...document.querySelectorAll('[data-interlinked-site-menu]')]
                        .filter(n => n.isConnected && getComputedStyle(n).visibility === 'hidden').length;
                      const shown = [...document.querySelectorAll('a[href],button')].filter(el => {
                        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
                        return r.bottom > 0 && r.top < 120 && r.width > 0 && s.visibility !== 'hidden' && s.display !== 'none';
                      }).map(el => (el.innerText || '').trim()).filter(Boolean).slice(0, 12);
                      return {hidden, siteLinksAtTop: shown};
                    })()
                    """)
                    let output = ProcessInfo.processInfo.environment["INTERLINKED_SITE_MENU_REPORT"] ?? "/tmp/interlinked-site-menu-report.json"
                    try? json(["report": report ?? NSNull()]).write(toFile: output, atomically: true, encoding: .utf8)
                }
                return ok()
            case "enable": workspace.usesSiteMenu = true
            case "disable": workspace.usesSiteMenu = false
            case "more":
                guard workspace.siteMenu != nil else { return error("this page has no site menu") }
                workspace.siteMenuExpanded = SiteMenuItem.moreID
            case "item":
                // By id, or by label as the bar shows it.
                let named = words.dropFirst().joined(separator: " ")
                let items = workspace.siteMenu.map { $0.items + $0.items.flatMap(\.children) } ?? []
                guard let item = items.first(where: { $0.id == named })
                        ?? items.first(where: { $0.label.caseInsensitiveCompare(named) == .orderedSame }) else {
                    return error("no site menu item '\(named)'")
                }
                workspace.activateSiteMenuItem(item)
            case "submit":
                guard workspace.siteMenu?.search != nil else { return error("this site menu has no search") }
                workspace.submitSiteSearch(words.dropFirst().joined(separator: " "))
            case "restore":
                workspace.restoreSiteHeader()
            case "state", nil: break
            default: return error("site-menu takes state, search, close, home, enable, disable, page, more, item ID, submit QUERY, or restore")
            }
            guard let menu = workspace.siteMenu else {
                return json(["shown": false, "uses_site_menu": workspace.usesSiteMenu])
            }
            return json([
                "shown": true,
                "uses_site_menu": workspace.usesSiteMenu,
                "home": menu.home,
                "name": menu.name,
                "replaces_chrome": menu.replacesChrome,
                "searching": workspace.siteMenuSearching,
                "expanded": workspace.siteMenuExpanded ?? "",
                "effect": workspace.siteMenuEffect != nil,
                "search": menu.search.map {
                    ["action": $0.action, "query_param": $0.queryParam, "placeholder": $0.placeholder]
                } ?? [:],
                "items": menu.items.map { item in
                    ["id": item.id, "label": item.label, "href": item.href, "current": item.current,
                     "children": item.children.map { ["id": $0.id, "label": $0.label, "href": $0.href] }] as [String: Any]
                },
            ])

        case "assistance-state":
            let a = workspace.assistance
            return json(["enabled": a.enabled, "key_saved": a.hasKey, "jev_ready": a.hasJevAccess, "status": a.status,
                         "matches": a.matches.map { ["id": $0.id, "text": $0.text] },
                         "label": workspace.activePane.map { a.label($0, url: workspace.surfaces.line($0)) } ?? "",
                         "origin": TrustedOrigin.inspect(workspace.currentPageURL)?.displayHost ?? "",
                         "origin_transport": TrustedOrigin.inspect(workspace.currentPageURL)?.transport.rawValue ?? "",
                         "can_share": a.canShare,
                         "granted_origins": a.originGrants.records,
                         "last_decision": a.lastDecisionStatus, "find_scores": a.findScores])

        case "find-page":
            workspace.assistance.openFind()
            workspace.assistance.query = words.joined(separator: " ")
            workspace.assistance.findChanged()
            return ok()

        case "close-page-tool":
            workspace.assistance.closePanel()
            return ok()


        case "page-icons":
            switch words.first {
            case "show": workspace.quickSwitchOpen = true
            case "hide": workspace.quickSwitchOpen = false
            case "toggle", nil: workspace.quickSwitchOpen.toggle()
            default: return error("page-icons takes show, hide, or toggle")
            }
            return ok()

        case "measure-frames":
            guard let pane = words.first.flatMap(UInt64.init).map({ PaneID($0) }) ?? workspace.activePane,
                  let view = workspace.hosts.existingBrowser(pane) else { return error("no loaded web page") }
            Task { @MainActor in
                do {
                    let metrics = try await view.evaluateJavaScript("""
                (async()=> await new Promise(resolve => {
                  const intervals = []; let previous, ticket;
                  function frame(now) {
                    if (previous !== undefined) intervals.push(now - previous);
                    previous = now;
                    ticket = requestAnimationFrame(frame);
                  }
                  ticket = requestAnimationFrame(frame);
                  setTimeout(() => {
                    cancelAnimationFrame(ticket);
                    const sorted = [...intervals].sort((a,b) => a-b);
                    const elapsed = intervals.reduce((a,b) => a+b, 0);
                    resolve({frames: intervals.length, fps: elapsed ? intervals.length * 1000 / elapsed : 0,
                      median_ms: sorted[Math.floor(sorted.length * .5)] ?? null,
                      p95_ms: sorted[Math.floor(sorted.length * .95)] ?? null,
                      over_25ms: intervals.filter(t => t > 25).length,
                      visibility: document.visibilityState});
                  }, 5000);
                }))()
                """)
                    let value: [String: Any] = ["pane": pane.rawValue, "web": metrics as Any, "display_hz": view.window?.screen?.maximumFramesPerSecond ?? 0]
                    let output = ProcessInfo.processInfo.environment["INTERLINKED_FRAME_REPORT"] ?? "/tmp/interlinked-frame-report.json"
                    try? json(value).write(toFile: output, atomically: true, encoding: .utf8)
                } catch { NSLog("Frame measurement failed: %@", error.localizedDescription) }
            }
            return ok()

        case "new-tab":
            let kind: Kind
            if let word = words.first {
                guard let parsed = Kind.parse(word), parsed == .browser || parsed == .blank else {
                    return error("no such kind '\(word)'. Try: \(kinds())")
                }
                kind = parsed
            } else {
                kind = .blank
            }
            workspace.openTab(kind: kind)
            workspace.beginEmptyPageEditingIfNeeded()
            return ok()

        case "open-url":
            guard let written = words.first,
                  let url = URL(string: written),
                  ExternalURLRouting.webURL(url) != nil else {
                return error("open-url needs one HTTP or HTTPS URL")
            }
            workspace.openExternalURLs([url])
            return ok()

        case "kind":
            guard let word = words.first, let kind = Kind.parse(word), kind == .browser || kind == .blank else {
                return error("kind needs one of: \(kinds())")
            }
            return withPane(workspace, words.dropFirst().first) { pane in
                workspace.setKind(pane, kind) ? ok() : error("no pane with that id")
            }

        case "close-tab", "close-pane":
            return withPane(workspace, words.first) { pane in
                workspace.closePane(pane) ? ok() : error("no pane with that id")
            }

        case "focus":
            return withPane(workspace, words.first) { pane in
                guard workspace.paneAlive(pane) else { return error("no pane with that id") }
                workspace.activatePane(pane)
                return ok()
            }

        case "focus-tab":
            guard let word = words.first, let index = Int(word), workspace.tabs.indices.contains(index) else {
                return error("no tab \(words.first ?? "")")
            }
            workspace.activateTab(index)
            return ok()

        case "next-tab":
            workspace.cycleTabs(1)
            return ok()

        case "prev-tab":
            workspace.cycleTabs(-1)
            return ok()

        case "move-tab":
            if let tab = words.first.flatMap({ UInt64($0) }),
               let slot = words.dropFirst().first.flatMap(Int.init) {
                workspace.dropTab(TabID(tab), slot: slot)
            }
            return ok()

        case "clear":
            return withPane(workspace, words.first) { pane in
                guard workspace.paneAlive(pane) else { return error("no pane with that id") }
                workspace.clearPane(pane)
                return ok()
            }

        case "listen":
            switch words.first {
            case nil:
                _ = workspace.startListening(.write)
                return ok()
            case "command":
                _ = workspace.startListening(.command)
                return ok()
            case "stop":
                workspace.stopListening()
                return ok()
            case let other?:
                return error("listen takes nothing, command, or stop, not '\(other)'")
            }

        case "dictate":
            let said = String(trimmed.drop(while: { !$0.isWhitespace }).dropFirst()).trimmingCharacters(in: .whitespaces)
            workspace.dictate(said)
            return ok()

        case "hear":
            let said = String(trimmed.drop(while: { !$0.isWhitespace }).dropFirst()).trimmingCharacters(in: .whitespaces)
            switch workspace.act(said) {
            case .ran(let command):
                return json(["ran": command])
            case .refused(let why):
                return error(why)
            case .notACommand:
                return error("'\(said)' is not a command")
            case .written:
                return error("that was written, not run")
            }

        case "edit":
            return withPane(workspace, words.first) { pane in
                workspace.editLine(pane) ? ok() : error("no pane with that id")
            }

        case "type":
            let text = String(trimmed.drop(while: { !$0.isWhitespace }).dropFirst())
            return workspace.typeInLine(text) ? ok() : error("no line is being written")

        case "commit":
            workspace.commitLine()
            return ok()

        case "discard":
            workspace.discardLine()
            return ok()

        case "tint":
            if words.isEmpty {
                return json([
                    "tint": workspace.tint.name,
                    "tints": Tint.allCases.map(\.name),
                ])
            }
            guard let tint = Tint.parse(words[0]) else {
                return error("no such tint '\(words[0])'. Try: \(Tint.allCases.map(\.name).joined(separator: " "))")
            }
            workspace.setTint(tint)
            return ok()

        case "identity":
            if words.isEmpty {
                let origin = TrustedOrigin.inspect(workspace.currentPageURL)
                return json([
                    "open": workspace.identityOpen,
                    "host": origin?.displayHost ?? "",
                    "ascii_host": origin?.asciiHost ?? "",
                    "transport": origin?.transport.rawValue ?? "",
                    "url": origin?.fullURL ?? "",
                    "mixed_script": origin?.mixedScript ?? false,
                    "label": workspace.activePane.map { workspace.assistance.label($0, url: workspace.surfaces.line($0)) } ?? "",
                ])
            }
            switch words[0] {
            case "hide":
                workspace.closeIdentity()
                return ok()
            case "show":
                workspace.identityOpen = false
                workspace.toggleIdentity()
                return ok()
            case "toggle":
                workspace.toggleIdentity()
                return ok()
            default:
                return error("identity wants show, hide, or toggle")
            }

        case "overview", "sidebar":
            if words.isEmpty {
                return json([
                    "open": workspace.overviewOpen,
                    "groups": workspace.assistance.groups.map { ["title": $0.title, "members": $0.members] as [String: Any] },
                ])
            }
            switch words[0] {
            case "search", "submit":
                // The overview's search field: matching tabs, and Return opens
                // the first match or goes to what was typed.
                let query = words.dropFirst().joined(separator: " ")
                let matches = workspace.tabs.filter { overviewMatches(query, $0, workspace) }
                if words[0] == "submit" {
                    if let tab = matches.first { workspace.selectWork(tab.id) }
                    else if !query.isEmpty { workspace.openAddress(query) }
                    return ok()
                }
                return json(["matches": matches.map { ["id": Int($0.id.rawValue), "title": workspace.title($0)] as [String: Any] }])
            case "hide", "collapse":
                workspace.setOverviewOpen(false)
                return ok()
            case "show", "expand":
                workspace.setOverviewOpen(true)
                return ok()
            case "toggle":
                workspace.toggleSidebar()
                return ok()
            default:
                guard let width = Double(words[0]), width.isFinite else {
                    return error("sidebar wants a width, or collapse, expand, toggle. Said '\(words[0])'")
                }
                workspace.setOverviewOpen(width > 0)
                return ok()
            }

        case "name-tab":
            if words.isEmpty {
                return json([
                    "tabs": workspace.tabs.enumerated().map { index, tab in
                        [
                            "index": index,
                            "name": tab.name ?? NSNull(),
                            "title": workspace.surfaces.tabTitle(tab),
                        ] as [String: Any]
                    },
                ])
            }
            let index: Int?
            let name: String
            if let parsed = Int(words[0]), words.count > 1 {
                index = parsed
                name = words.dropFirst().joined(separator: " ")
            } else {
                index = nil
                name = words.joined(separator: " ")
            }
            let tab: Tab?
            if let index {
                tab = workspace.tabs.indices.contains(index) ? workspace.tabs[index] : nil
            } else {
                tab = workspace.activeTab
            }
            guard let tab else { return error("no tab \(String(describing: index))") }
            workspace.nameTab(tab.id, name)
            return ok()

        case "clear-tab":
            return withTab(workspace, words.first) { tab in
                workspace.nameTab(tab.id, "")
                return ok()
            }

        case "builtins":
            let builtIns = workspace.builtIns
            switch words.first ?? "state" {
            case "state":
                return json([
                    "blocking": builtIns.blockingEnabled,
                    "engine_ready": builtIns.engineReady,
                    "dark_mode": builtIns.darkMode.rawValue,
                    "page_darkened": builtIns.darkens(workspace.currentPageURL),
                    "status": builtIns.status,
                ])
            case "blocking":
                guard words.count == 2, ["on", "off"].contains(words[1]) else { return error("builtins blocking takes on or off") }
                builtIns.blockingEnabled = words[1] == "on"
                return ok()
            case "dark":
                guard words.count == 2, let mode = PageDarkMode(rawValue: words[1]) else {
                    return error("builtins dark takes off, system, or always")
                }
                builtIns.darkMode = mode
                return ok()
            default:
                return error("builtins takes state, blocking on|off, or dark off|system|always")
            }

        case "onboarding":
            switch words.first ?? "state" {
            case "open": workspace.openOnboarding()
            case "close": workspace.closeOnboarding()
            case "reset": workspace.onboarding.reset()
            case "step":
                guard let step = words.dropFirst().first.flatMap(OnboardingStep.init(rawValue:)) else {
                    return error("onboarding step takes one of: \(OnboardingStep.allCases.map(\.rawValue).joined(separator: " "))")
                }
                workspace.advanceOnboarding(step)
            case "feature":
                guard words.count == 3, let feature = OnboardingFeature(rawValue: words[1]), let on = onOff(words[2]) else {
                    return error("onboarding feature takes a feature from the scene and on or off")
                }
                workspace.binding(for: feature).wrappedValue = on
            case "state": break
            default: return error("onboarding takes open, close, reset, step STEP, feature FEATURE on|off, or state")
            }
            return json(([
                "open": workspace.onboarding.pane != nil,
                "focused": workspace.onboarding.contains(workspace.activePane),
                "scene": workspace.onboarding.progress.scene.id,
                "done": workspace.onboarding.progress.done.map(\.rawValue),
                "next": workspace.onboarding.progress.next?.rawValue ?? "",
                "notice": workspace.onboarding.notice ?? "",
                "coach": workspace.showsOnboardingCoach,
                "shortcut_1": workspace.quickTabs.first.map { workspace.title($0) } ?? "",
                "tabs": workspace.tabs.count,
            ] as [String: Any]).merging(onboardingDetail(workspace)) { $1 })

        case "split-view":
            switch words.first ?? "state" {
            case "on": if !workspace.isSplit { workspace.splitActive() }
            case "off": workspace.unsplit()
            case "other": workspace.focusOtherPane()
            case "ratio":
                guard words.count == 2, let value = Double(words[1]) else { return error("split-view ratio takes a number") }
                workspace.setSplitRatio(value)
            case "drop":
                guard words.count == 3, let raw = UInt64(words[1]), ["left", "right"].contains(words[2]) else {
                    return error("split-view drop takes a tab id and left or right")
                }
                workspace.dropTab(TabID(raw), leading: words[2] == "left")
            case "state": break
            default: return error("split-view takes on, off, other, or state")
            }
            return json([
                "split": workspace.isSplit,
                "panes": workspace.activeTab?.panes.map { Int($0.rawValue) } ?? [],
                "active": workspace.activePane.map { Int($0.rawValue) } ?? 0,
                "tabs": workspace.tabs.count,
                "tab_ids": workspace.tabs.map { Int($0.id.rawValue) },
                "ratio": workspace.activeTab?.splitRatio ?? 0.5,
            ])

        case "sharing-mode":
            switch words.first ?? "state" {
            case "on": workspace.sharingScreenMode = true
            case "off": workspace.sharingScreenMode = false
            case "state": break
            case "check":
                // Writes what the active page covers, for fixtures.
                guard let view = workspace.activePane.flatMap(workspace.hosts.existingBrowser) else { return error("no loaded web page") }
                Task { @MainActor in
                    let covered = try? await view.evaluateJavaScript("globalThis.__interlinkedShield?.covered() ?? null")
                    let output = ProcessInfo.processInfo.environment["INTERLINKED_SHIELD_REPORT"] ?? "/tmp/interlinked-shield-report.json"
                    try? json(["enabled": workspace.sharingScreenMode, "covered": covered ?? NSNull()]).write(toFile: output, atomically: true, encoding: .utf8)
                }
            default: return error("sharing-mode takes on, off, state, or check")
            }
            return json(["enabled": workspace.sharingScreenMode])

        case "quit":
            workspace.quit()
            return ok()

        default:
            return error("unknown command '\(command)'. Try: commands")
        }
    }

    @MainActor
    private static func snapshot(_ workspace: Workspace) -> [String: Any] {
        let tabs: [[String: Any]] = workspace.tabs.enumerated().map { index, tab in
            [
                "id": Int(tab.id.rawValue),
                "active": index == workspace.active,
                "focus": Int(tab.active.rawValue),
                "title": workspace.title(tab),
                "name": tab.name ?? NSNull(),
                "split": tab.isSplit,
                "split_ratio": tab.splitRatio,
                "tree": tree(tab.root, root: tab.root, workspace: workspace),
            ]
        }
        return [
            "voice": voiceState(workspace.voice),
            "web": true,
            "tint": workspace.tint.name,
            "sidebar": Double(workspace.sidebar),
            "overview": workspace.overviewOpen,
            "identity": workspace.identityOpen,
            "page_history": workspace.pageHistoryOpen,
            "recently_closed": workspace.recentlyClosed.reversed().map { closed in
                ["url": closed.url, "name": closed.name ?? NSNull(), "closed": timestamp(closed.closed)] as [String: Any]
            },
            "downloads_panel": workspace.downloads.panelOpen,
            "quick_switch": workspace.quickSwitchOpen,
            "page_tool": panelName(workspace.assistance.panel),
            "contact_open": workspace.usefulInfo.contactOpen,
            "site_menu": [
                "shown": workspace.siteMenu != nil,
                "expanded": workspace.siteMenuExpanded ?? NSNull(),
                "searching": workspace.siteMenuSearching,
            ] as [String: Any],
            "onboarding": workspace.onboarding.pane != nil,
            "settings_window": settingsWindow()?.isVisible ?? false,
            "sharing_screen_mode": workspace.sharingScreenMode,
            "command_keys": ["left": workspace.leftCommandKeyHeld, "right": workspace.rightCommandKeyHeld],
            "origin": TrustedOrigin.inspect(workspace.currentPageURL)?.displayHost ?? "",
            "writing": writing(workspace),
            "active_tab": workspace.active,
            "active_pane": workspace.activePane.map { Int($0.rawValue) } ?? NSNull(),
            "tabs": tabs,
        ]
    }

    @MainActor
    private static func onboardingDetail(_ workspace: Workspace) -> [String: Any] {
        let guide = workspace.onboarding
        var features: [String: Bool] = [:]
        for feature in guide.progress.scene.features {
            features[feature.rawValue] = workspace.binding(for: feature).wrappedValue
        }
        let pane: Any = guide.pane.map { Int($0.rawValue) } ?? NSNull()
        let side: Any = guide.sidePane.map { Int($0.rawValue) } ?? NSNull()
        return [
            "pane": pane,
            "side_pane": side,
            "steps": guide.progress.scene.steps.map(\.rawValue),
            "features": features,
            "always_show": guide.alwaysShow,
        ]
    }

    @MainActor
    private static func writing(_ workspace: Workspace) -> Any {
        guard let editing = workspace.editing else { return NSNull() }
        switch editing.target {
        case .pane(let pane): return ["pane": Int(pane.rawValue), "text": editing.text]
        case .tab(let tab): return ["tab": Int(tab.rawValue), "text": editing.text]
        }
    }

    @MainActor
    private static func tree(_ pane: Pane, root: Pane, workspace: Workspace) -> [String: Any] {
        switch pane {
        case .leaf(let id):
            let (row, column) = root.coordinate(id)
            let page = workspace.hosts.existingBrowser(id)
            let node: [String: Any] = [
                "pane": Int(id.rawValue),
                "coordinate": "\(row)-\(column)",
                "kind": workspace.surfaces.kind(id).name,
                "line": workspace.surfaces.line(id),
                "title": workspace.title(id),
                "live": page != nil,
                "url": page?.url?.absoluteString ?? NSNull(),
                "loading": page?.isLoading ?? false,
                "can_go_back": workspace.hosts.canGoBack[id, default: false],
                "can_go_forward": workspace.hosts.canGoForward[id, default: false],
                "recovery": workspace.hosts.recovery(for: id)?.cause.rawValue ?? NSNull(),
                "onboarding": workspace.onboarding.contains(id),
            ]
            return node
        case .split(let id, let axis, let first, let second):
            return [
                "split": Int(id.rawValue),
                "axis": axis.rawValue,
                "children": [
                    tree(first, root: root, workspace: workspace),
                    tree(second, root: root, workspace: workspace),
                ],
            ]
        }
    }

    @MainActor
    private static func voiceState(_ voice: Voice) -> [String: Any] {
        let mode = voice.mode.rawValue
        switch voice.state {
        case .idle:
            return ["state": "idle"]
        case .starting:
            return ["state": "starting", "mode": mode]
        case .listening(let heard, _):
            return ["state": "listening", "mode": mode, "heard": heard, "level": Double(voice.currentLevel)]
        case .finishing(let heard):
            return ["state": "finishing", "heard": heard]
        case .heard(let said, let outcome):
            let mapped: Any
            switch outcome {
            case .ran(let command): mapped = ["ran": command]
            case .refused(let why): mapped = ["refused": why]
            case .notACommand: mapped = "not a command"
            case .written: mapped = "written"
            }
            return ["state": "heard", "said": said, "outcome": mapped]
        case .failed(let why):
            return ["state": "failed", "why": why]
        }
    }

    /// A tab index argument. A word that is not an open tab's index is an
    /// error, never the active tab.
    @MainActor
    static func withTab(_ workspace: Workspace, _ named: String?, _ body: (Tab) -> String) -> String {
        let tab: Tab?
        if let named {
            guard let index = Int(named), workspace.tabs.indices.contains(index) else { return error("no tab \(named)") }
            tab = workspace.tabs[index]
        } else {
            tab = workspace.activeTab
        }
        guard let tab else { return error("there are no tabs") }
        return body(tab)
    }

    @MainActor
    static func withPane(_ workspace: Workspace, _ named: String?, _ body: (PaneID) -> String) -> String {
        let pane: PaneID?
        if let named {
            guard let id = UInt64(named) else { return error("no pane with that id") }
            pane = PaneID(id)
        } else {
            pane = workspace.activePane
        }
        guard let pane else { return error("there are no panes") }
        return body(pane)
    }

    private static func kinds() -> String {
        [Kind.browser].map(\.name).joined(separator: " ")
    }

    static func ok() -> String { "ok" }

    static func error(_ why: String) -> String { "error \(why)" }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

final class ControlServer {
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var running = false

    func start(handler: @escaping (String) -> String) {
        let path = Control.socketPath()
        let usingOverride = ProcessInfo.processInfo.environment["INTERLINKED_SOCKET"] != nil

        let probe = sockaddr_un()
        let sunPathCapacity = MemoryLayout.size(ofValue: probe.sun_path)
        let pathByteCount = path.utf8CString.count
        guard pathByteCount <= sunPathCapacity else {
            fputs("interlinked: control socket path too long (\(pathByteCount) > \(sunPathCapacity))\n", stderr)
            return
        }

        if usingOverride {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        } else {
            guard Self.ensureControlDirectory(for: path) else {
                fputs("interlinked: could not secure control directory for \(path)\n", stderr)
                return
            }
        }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fputs("interlinked: could not listen on \(path)\n", stderr)
            return
        }
        Self.setNoSigPipe(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        memset(&addr.sun_path, 0, sunPathCapacity)
        let filled = path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest -> Bool in
                guard let base = dest.baseAddress else { return false }
                // pathByteCount includes the NUL terminator and fits.
                memcpy(base, cstr, pathByteCount)
                return true
            }
        }
        guard filled else {
            close(fd)
            fputs("interlinked: could not listen on \(path)\n", stderr)
            return
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.bind(fd, sock, len)
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            fputs("interlinked: could not listen on \(path)\n", stderr)
            return
        }
        // The socket lives in a 0700 directory; lock the node itself down too.
        _ = path.withCString { Darwin.chmod($0, 0o600) }
        listenFD = fd
        running = true
        print("interlinked: control channel on \(path)")
        let thread = Thread { [weak self] in
            while self?.running == true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if self?.running == true { continue }
                    break
                }
                // Handle each client off the accept thread so one slow or
                // wedged peer cannot starve the channel.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { Darwin.close(client); return }
                    self.handleClient(client, handler: handler)
                }
            }
        }
        thread.start()
        self.thread = thread
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            let fd = listenFD
            listenFD = -1
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(Control.socketPath())
    }

    private static func ensureControlDirectory(for socketPath: String) -> Bool {
        let dir = (socketPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        } catch {
            return false
        }
        // Confirm we own the directory and nobody else can write to it.
        var st = stat()
        guard stat(dir, &st) == 0, st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else {
            return false
        }
        return true
    }

    private static func setNoSigPipe(_ fd: Int32) {
        var opt: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval()
        tv.tv_sec = __darwin_time_t(seconds)
        tv.tv_usec = __darwin_suseconds_t(0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handleClient(_ client: Int32, handler: @escaping (String) -> String) {
        defer { Darwin.close(client) }
        Self.setNoSigPipe(client)
        Self.setTimeout(client, seconds: Control.receiveTimeoutSeconds)

        // Only our own uid may drive the browser (type/dictate carry keystrokes).
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            return
        }

        var data = Data()
        data.reserveCapacity(4096)
        var sawNewline = false
        var tooLarge = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !sawNewline && !tooLarge {
            let n = chunk.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.read(client, base, buf.count)
            }
            if n == 0 { break } // EOF
            if n < 0 {
                if errno == EINTR { continue }
                break // timeout (EAGAIN/EWOULDBLOCK) or other error
            }
            for i in 0..<n {
                let byte = chunk[i]
                if byte == 10 {
                    sawNewline = true
                    break
                }
                if byte == 13 { continue }
                if data.count >= Control.maxRequestBytes {
                    tooLarge = true
                    break
                }
                data.append(byte)
            }
        }

        if tooLarge {
            Self.writeAll(client, string: "error request too large\n")
            return
        }
        // A peer that connected and said nothing (or timed out) just goes away.
        guard sawNewline || !data.isEmpty else { return }

        let request = String(data: data, encoding: .utf8) ?? ""
        let reply = DispatchQueue.main.sync { handler(request) } + "\n"
        Self.writeAll(client, string: reply)
    }

    private static func writeAll(_ fd: Int32, string: String) {
        string.withCString { cstr in
            var ptr = UnsafeRawPointer(cstr)
            var remaining = strlen(cstr)
            while remaining > 0 {
                let written = Darwin.write(fd, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    break // EPIPE (peer closed) or timeout; SO_NOSIGPIPE keeps this from signalling.
                }
                if written == 0 { break }
                remaining -= Int(written)
                ptr = ptr.advanced(by: Int(written))
            }
        }
    }
}
