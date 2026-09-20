import SwiftUI

struct EmptyPaneView: View {
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
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.textDim)
            }
        }
        .allowsHitTesting(false)
    }
}
