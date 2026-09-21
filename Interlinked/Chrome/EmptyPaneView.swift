import AppKit
import SwiftUI

private let savedSiteSlot: CGFloat = 28

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
            if workspace.savedSites.showsOnNewTab {
                VStack {
                    SavedSitesStrip(palette: palette)
                        .padding(.top, 56)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { workspace.refreshMissingSavedSiteIcons() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-tab-page")
    }
}

private struct SavedSitesStrip: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette

    var body: some View {
        Group {
            if let kind = workspace.newTabEditor {
                SavedSiteAddField(kind: kind, palette: palette)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    SavedSiteLane(kind: .favorite, sites: workspace.savedSites.favorites, palette: palette)
                    SavedSiteLane(kind: .bookmark, sites: workspace.savedSites.bookmarks, palette: palette)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(palette.text)
        .modifier(PageGlass(radius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-tab-saved-sites")
    }
}

private struct SavedSiteLane: View {
    @Environment(Workspace.self) private var workspace
    var kind: SavedSiteKind
    var sites: [SavedSite]
    var palette: Palette

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            StripGlyph(kind.symbol, palette: palette)
                .accessibilityHidden(true)
            ForEach(sites) { site in
                Button { workspace.openPage(site.url) } label: {
                    SavedSiteIcon(site: site, palette: palette)
                }
                .buttonStyle(.pointing)
                .accessibilityLabel(site.title)
                .accessibilityIdentifier("saved-site-\(site.id.uuidString)")
                .help(site.title)
                .contextMenu {
                    Button("Remove") { workspace.savedSites.remove(site.id, from: kind) }
                }
            }
            Button { workspace.beginNewTabEditor(kind) } label: {
                StripGlyph("plus", palette: palette)
            }
            .buttonStyle(.pointing)
            .accessibilityLabel("Add \(kind.accessibilityName.lowercased())")
            .accessibilityIdentifier("new-tab-add-\(kind.rawValue)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.accessibilityName)
        .accessibilityIdentifier("new-tab-\(kind.rawValue)s")
    }
}

private struct SavedSiteAddField: View {
    @Environment(Workspace.self) private var workspace
    var kind: SavedSiteKind
    var palette: Palette
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            StripGlyph(kind.symbol, palette: palette)
                .accessibilityHidden(true)
            WorkInput(
                text: $draft,
                placeholder: "example.com",
                identifier: "new-tab-editor-\(kind.rawValue)",
                fontSize: 12,
                palette: palette,
                submit: submit,
                cancel: cancel
            )
            .frame(width: 220, height: savedSiteSlot)
            Button("Add", action: submit)
                .buttonStyle(.pointing)
                .font(.system(size: 12, weight: .medium))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("new-tab-submit-\(kind.rawValue)")
            Button(action: cancel) {
                StripGlyph("xmark", palette: palette)
            }
            .buttonStyle(.pointing)
            .accessibilityLabel("Cancel adding \(kind.accessibilityName.lowercased())")
            .accessibilityIdentifier("new-tab-cancel-\(kind.rawValue)")
        }
        .onExitCommand(perform: cancel)
    }

    private func submit() {
        if workspace.submitNewTabSite(draft) { draft = "" }
    }

    private func cancel() {
        draft = ""
        workspace.cancelNewTabEditor()
    }
}

private struct StripGlyph: View {
    var name: String
    var palette: Palette

    init(_ name: String, palette: Palette) {
        self.name = name
        self.palette = palette
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.text)
            .frame(width: savedSiteSlot, height: savedSiteSlot)
            .contentShape(Rectangle())
    }
}

private struct SavedSiteIcon: View {
    @Environment(Workspace.self) private var workspace
    var site: SavedSite
    var palette: Palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.hover)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: savedSiteSlot, height: savedSiteSlot)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Text(letter)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.text)
            }
        }
        .frame(width: savedSiteSlot, height: savedSiteSlot)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var image: NSImage? {
        if let data = site.icon, let image = NSImage(data: data) { return image }
        if let domain = DomainIconCache<NSImage>.domain(URL(string: site.url)),
           let data = workspace.hosts.storedIconData(for: domain),
           let image = NSImage(data: data) {
            return image
        }
        return nil
    }

    private var letter: String {
        let scalar = site.title.unicodeScalars.first { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        return scalar.map { String($0).uppercased() } ?? "#"
    }
}
