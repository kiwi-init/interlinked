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
            }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .sidebar) {
                Button("All Tabs") { workspace.toggleOverview() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandMenu("Tab") {
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
                Button("Downloads") {
                    workspace.assistance.closeFilters()
                    if workspace.assistance.panel != nil { workspace.assistance.closePanel() }
                    workspace.downloads.togglePanel()
                }
                .keyboardShortcut("j", modifiers: .command)
                Divider()
                Button("Close Tab") { workspace.closeActive() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Edit Address") { workspace.editActiveLine() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Reload Page") {
                    if let pane = workspace.activePane { workspace.hosts.existingBrowser(pane)?.reload() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        Window("About Interlinked", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        Settings { AssistanceSettings().environment(workspace) }
            .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            self?.updateApplicationIcon(for: app.effectiveAppearance)
        }
    }

    private func updateApplicationIcon(for appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = isDark ? NSImage(named: "AppIconDark") : nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        Workspace.shared?.stop()
    }
}
