import SwiftUI

/// The page's address and contact details as copy buttons above the toolbox.
/// Contact grows in place into its choices when there is more than one.
struct UsefulInfoStack: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette

    private var info: UsefulInfo { workspace.usefulInfo }

    var body: some View {
        Group {
            if let found = info.active, !workspace.overviewOpen {
                VStack(alignment: .trailing, spacing: 8) {
                    if let address = found.address {
                        AddressButton(address: address, palette: palette)
                    }
                    if !found.options.isEmpty {
                        ContactGroup(options: found.options, palette: palette)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Metrics.morph, value: info.active)
        .onChange(of: workspace.activePane) { _, _ in info.contactOpen = false }
    }
}

private enum UsefulInfoMetrics {
    static let row: CGFloat = 40
    static let icon: CGFloat = 40
    static let valueWidth: CGFloat = 250
}

private struct AddressButton: View {
    @Environment(Workspace.self) private var workspace
    var address: String
    var palette: Palette

    private var copied: Bool { workspace.usefulInfo.copied == address }

    var body: some View {
        Button { workspace.usefulInfo.copy(address) } label: {
            UsefulInfoRow(symbol: copied ? "checkmark" : "map", text: copied ? "Address copied" : address)
                .frame(height: UsefulInfoMetrics.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .foregroundStyle(palette.text)
        .modifier(PageGlass(radius: 14))
        .help("Copy address · \(address)")
        .accessibilityLabel("Copy address, \(address)")
        .accessibilityIdentifier("useful-address")
    }
}

private struct ContactGroup: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var options: [ContactOption]
    var palette: Palette

    private var info: UsefulInfo { workspace.usefulInfo }
    private var open: Bool { info.contactOpen && options.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if open {
                HStack(spacing: 0) {
                    Image(systemName: "person.crop.circle")
                        .frame(width: UsefulInfoMetrics.icon)
                    Text("Copy contact")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 12)
                    Button { info.contactOpen = false } label: {
                        Image(systemName: "xmark")
                            .frame(width: UsefulInfoMetrics.icon, height: UsefulInfoMetrics.row)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointing)
                    .accessibilityLabel("Close contact options")
                }
                .frame(height: UsefulInfoMetrics.row)
                ForEach(options) { option in
                    Button { copy(option.value) } label: {
                        UsefulInfoRow(
                            symbol: info.copied == option.value ? "checkmark" : symbol(option.kind),
                            text: info.copied == option.value ? "Copied" : option.value
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: UsefulInfoMetrics.row)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointing)
                    .accessibilityLabel("Copy \(option.value)")
                    .accessibilityIdentifier("useful-contact-\(option.value)")
                }
                .transition(.opacity)
            } else {
                Button(action: activate) { collapsed }
                    .buttonStyle(.pointing)
                    .help(options.count > 1 ? "Show contact options" : "Copy \(options[0].value)")
                    .accessibilityLabel(options.count > 1 ? "Contact, \(options.count) options" : "Copy contact, \(options[0].value)")
                    .accessibilityIdentifier("useful-contact")
            }
        }
        .frame(width: open ? UsefulInfoMetrics.icon + UsefulInfoMetrics.valueWidth + 14 : nil, alignment: .leading)
        .foregroundStyle(palette.text)
        .modifier(PageGlass(radius: 14))
        .onExitCommand { info.contactOpen = false }
        .animation(reduceMotion ? nil : Metrics.morph, value: open)
    }

    private var collapsed: some View {
        let first = options[0]
        let copied = info.copied == first.value && options.count == 1
        return HStack(spacing: 0) {
            UsefulInfoRow(symbol: copied ? "checkmark" : symbol(first.kind), text: copied ? "Copied" : first.value)
            if options.count > 1 {
                Text("+\(options.count - 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textDim)
                    .padding(.trailing, 14)
                    .padding(.leading, -6)
            }
        }
        .frame(height: UsefulInfoMetrics.row)
        .contentShape(Rectangle())
    }

    private func activate() {
        if options.count == 1 { info.copy(options[0].value) } else { info.contactOpen = true }
    }

    private func copy(_ value: String) {
        info.copy(value)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if info.copied == value { info.contactOpen = false }
        }
    }

    private func symbol(_ kind: ContactOption.Kind) -> String {
        switch kind {
        case .phone: "phone"
        case .email: "envelope"
        }
    }
}

/// Icon column first, then the value, so every row in a group lines up.
private struct UsefulInfoRow: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: UsefulInfoMetrics.icon)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: UsefulInfoMetrics.valueWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 14)
        }
    }
}
