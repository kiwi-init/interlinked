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
        Settings { AssistanceSettings().environment(workspace) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
