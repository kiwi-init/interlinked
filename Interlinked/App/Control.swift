import Darwin
import Foundation
import AppKit

enum Control {
    static let writeCommands = [
        "new-tab [kind]",
        "open-url URL",
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
        "site-menu [state|search|close]",
        "quit",
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
                "reads": ["state", "commands", "identity", "measure-frames [pane]", "site-menu"],
                "writes": writeCommands,
            ])

        case "state":
            return json(snapshot(workspace))

        case "engine-state":
            return json([
                "engine": ILChromiumRuntime.engineVersion,
                "running": ILChromiumRuntime.isRunning,
                "application_class": NSStringFromClass(type(of: NSApp)),
                "active_pages": workspace.tabs.filter { workspace.hosts.existingBrowser($0.active) != nil }.count,
            ])

        case "site-menu":
            switch words.first {
            case "search": workspace.beginSiteMenuSearch()
            case "close": workspace.collapseSiteMenuChrome()
            case "state", nil: break
            default: return error("usage: site-menu [state|search|close]")
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
                "items": menu.items.map { ["label": $0.label, "children": $0.children.count] },
            ])

        case "assistance-state":
            let a = workspace.assistance
            return json(["enabled": a.enabled, "key_saved": a.hasKey, "jev_ready": a.hasJevAccess, "status": a.status,
                         "matches": a.matches.map { ["id": $0.id, "text": $0.text] },
                         "findings": a.findings.map { ["id": $0.id, "category": $0.signal.rawValue] },
                         "label": workspace.activePane.map { a.label($0, url: workspace.surfaces.line($0)) } ?? "",
                         "origin": TrustedOrigin.inspect(workspace.currentPageURL)?.displayHost ?? "",
                         "origin_transport": TrustedOrigin.inspect(workspace.currentPageURL)?.transport.rawValue ?? "",
                         "can_share": a.canShare,
                         "automatic_reading": a.automaticReadingEnabled,
                         "granted_origins": a.originGrants.records,
                         "last_decision": a.lastDecisionStatus, "find_scores": a.findScores])

        case "find-page":
            workspace.assistance.openFind()
            workspace.assistance.query = words.joined(separator: " ")
            workspace.assistance.findChanged()
            return ok()

        case "check-wording":
            workspace.assistance.openReading()
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
            let named = words.first.flatMap { UInt64($0) }.map { PaneID($0) }
            let pane = named ?? workspace.activePane
            guard let pane else { return error("there are no panes to close") }
            return workspace.closePane(pane) ? ok() : error("no pane with that id")

        case "focus":
            return withPane(workspace, words.first) { pane in
                workspace.activatePane(pane)
                return ok()
            }

        case "focus-tab":
            if let index = words.first.flatMap(Int.init) {
                workspace.activateTab(index)
            }
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
            let named = words.first.flatMap { UInt64($0) }.map { PaneID($0) }
            let pane = named ?? workspace.activePane
            guard let pane else { return error("there is no pane to write in") }
            return workspace.editLine(pane) ? ok() : error("no pane with that id")

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
                ])
            }
            switch words[0] {
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
            let index = words.first.flatMap(Int.init)
            let tab: Tab?
            if let index {
                tab = workspace.tabs.indices.contains(index) ? workspace.tabs[index] : nil
            } else {
                tab = workspace.activeTab
            }
            guard let tab else { return error("no tab \(String(describing: index))") }
            workspace.nameTab(tab.id, "")
            return ok()

        case "builtins":
            let builtIns = workspace.builtIns
            switch words.first ?? "state" {
            case "state":
                return json([
                    "blocking": builtIns.blockingEnabled,
                    "engine_ready": builtIns.engineReady,
                    "blocked_on_page": workspace.activePane.flatMap { builtIns.blockedCounts[$0] } ?? 0,
                    "blocked_total": builtIns.blockedTotal,
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
            "origin": TrustedOrigin.inspect(workspace.currentPageURL)?.displayHost ?? "",
            "writing": writing(workspace),
            "tabs": tabs,
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
            let node: [String: Any] = [
                "pane": Int(id.rawValue),
                "coordinate": "\(row)-\(column)",
                "kind": workspace.surfaces.kind(id).name,
                "line": workspace.surfaces.line(id),
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

    @MainActor
    private static func withPane(_ workspace: Workspace, _ named: String?, _ body: (PaneID) -> String) -> String {
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

    private static func ok() -> String { "ok" }

    private static func error(_ why: String) -> String { "error \(why)" }

    private static func json(_ object: Any) -> String {
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
