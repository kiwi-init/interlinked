import SwiftUI

@main
struct InterlinkedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 880, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            AboutCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Page") { workspace.newPage() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Page Beside") { workspace.newPageBeside() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Close Tab") { workspace.closeActive() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .sidebar) {
                Button("All Tabs") { workspace.toggleOverview() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandGroup(replacing: .help) {
                Button("Show Onboarding") { workspace.openOnboarding() }
            }
            CommandMenu("Tab") {
                Button("Reopen Closed Tab") { workspace.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(workspace.recentlyClosed.isEmpty)
                Divider()
                Button(workspace.isSplit ? "Move Side Page to Its Own Tab" : "Split View") { workspace.toggleSplitView() }
                    .keyboardShortcut("\\", modifiers: .command)
                Button("Focus Other Page") { workspace.focusOtherPane() }
                    .keyboardShortcut("\\", modifiers: [.command, .option])
                    .disabled(!workspace.isSplit)
                Divider()
                Button("Next Tab") { workspace.cycleTabs(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous Tab") { workspace.cycleTabs(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Cycle Pages Forward") { workspace.cycleTabs(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Cycle Pages Backward") { workspace.cycleTabs(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            CommandMenu("Page") {
                Button("Find in Page") { workspace.assistance.openFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { workspace.assistance.moveMatch(1) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { workspace.assistance.moveMatch(-1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Critical Reading…") { workspace.assistance.openReading() }
                Button("Share This Page with Jev…") { workspace.assistance.requestSharing() }
                Button("Stop Sharing This Page") { workspace.assistance.revokePage() }
                    .disabled(!workspace.assistance.shared)
                Button("Downloads") { workspace.toggleDownloads() }
                .keyboardShortcut("j", modifiers: .command)
                Toggle("Sharing Screen Mode", isOn: Binding(
                    get: { workspace.sharingScreenMode },
                    set: { workspace.sharingScreenMode = $0 }
                ))
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Connection Details") { workspace.toggleIdentity() }
                    .disabled(workspace.currentPageURL == nil)
                Button("Edit Address") { workspace.editActiveLine() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Reload Page") {
                    workspace.reloadActivePage()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Copy Page URL") { workspace.copyCurrentPageURL() }
                    .disabled(workspace.currentPageURL == nil)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        Window("About Interlinked", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        Settings { InterlinkedSettings().environment(workspace) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 840, height: 620)
            .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?
    private var pendingWebURLs: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Every window shares one Workspace and its page views, and an NSView
        // can live in only one window.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            self?.updateApplicationIcon(for: app.effectiveAppearance)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.compactMap(ExternalURLRouting.webURL)
        guard !urls.isEmpty else { return }
        if let workspace = Workspace.shared {
            workspace.openExternalURLs(urls)
        } else {
            pendingWebURLs.append(contentsOf: urls)
        }
    }

    func takePendingWebURLs() -> [URL] {
        defer { pendingWebURLs.removeAll() }
        return pendingWebURLs
    }

    private func updateApplicationIcon(for appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = isDark ? NSImage(named: "AppIconDark") : nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        Workspace.shared?.stop()
    }
}
