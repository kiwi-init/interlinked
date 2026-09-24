import SwiftUI

struct EmptyPaneView: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette

    var body: some View {
        ZStack {
            palette.pane
            VStack(spacing: 14) {
                Text("\"Within cells interlinked\"")
                    .font(.system(size: 30, weight: .regular, design: .serif).italic())
                    .foregroundStyle(palette.text)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.left")
                        .accessibilityHidden(true)
                    Text("Search or enter an address")
                }
                .font(.system(size: 13))
                .foregroundStyle(palette.textDim)
            }
            .padding(.bottom, 72)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-tab-page")
    }
}
