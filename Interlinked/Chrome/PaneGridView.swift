import SwiftUI

struct BrowserPage: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID
    var palette: Palette

    var body: some View {
        Group {
            if let recovery = workspace.hosts.recovery(for: pane) {
                BrowserRecoveryView(pane: pane, recovery: recovery, palette: palette)
            } else if workspace.surfaces.line(pane).isEmpty {
                EmptyPaneView(palette: palette)
            } else {
                BrowserPane(pane: pane)
            }
        }
        .background(palette.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowserRecoveryView: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID
    var recovery: BrowserRecovery
    var palette: Palette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: recovery.cause == .memoryPressure ? "memorychip" : "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(palette.textDim)
            VStack(spacing: 6) {
                Text(recovery.cause.title)
                    .font(.system(size: 16, weight: .semibold))
                Text(recovery.cause.message)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }
            Button(recovery.cause.action) { workspace.recoverPane(pane) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("browser-recovery-action")
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-recovery")
    }
}
