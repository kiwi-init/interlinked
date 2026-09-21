import AppKit
import SwiftUI

struct EmptyPaneView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            Image(NewTabArt.imageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityHidden(true)
            LinearGradient(
                colors: [Color.black.opacity(0.08), Color.black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(spacing: 22) {
                Spacer(minLength: 48)
                SavedSiteSection(
                    title: "Favorites",
                    kind: .favorite,
                    sites: workspace.savedSites.favorites,
                    emptyHint: "Sites you want at hand"
                )
                SavedSiteSection(
                    title: "Bookmarks",
                    kind: .bookmark,
                    sites: workspace.savedSites.bookmarks,
                    emptyHint: "Saved for later"
                )
                Spacer(minLength: 96)
            }
            .padding(.horizontal, 48)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        workspace.openPage(NewTabArt.artistURL.absoluteString)
                    } label: {
                        Text("Art by \(NewTabArt.artistName)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                    }
                    .buttonStyle(.pointing)
                    .accessibilityLabel("Art by \(NewTabArt.artistName)")
                    .accessibilityIdentifier("new-tab-artist")
                    .help("https://x.com/Techniacus")
                }
                .padding(.trailing, 140)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-tab-page")
    }
}

private struct SavedSiteSection: View {
    @Environment(Workspace.self) private var workspace
    var title: String
    var kind: SavedSiteKind
    var sites: [SavedSite]
    var emptyHint: String
    @State private var draft = ""

    private var editing: Bool { workspace.newTabEditor == kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer(minLength: 8)
                if editing {
                    Button {
                        draft = ""
                        workspace.cancelNewTabEditor()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointing)
                    .accessibilityLabel("Cancel adding \(title.lowercased())")
                    .accessibilityIdentifier("new-tab-cancel-\(kind.rawValue)")
                } else {
                    Button {
                        draft = ""
                        workspace.beginNewTabEditor(kind)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointing)
                    .accessibilityLabel("Add \(title.lowercased())")
                    .accessibilityIdentifier("new-tab-add-\(kind.rawValue)")
                }
            }
            if editing {
                HStack(spacing: 8) {
                    WorkInput(
                        text: $draft,
                        placeholder: "example.com",
                        identifier: "new-tab-editor-\(kind.rawValue)",
                        fontSize: 12,
                        palette: .dark(.ink),
                        submit: submit,
                        cancel: {
                            draft = ""
                            workspace.cancelNewTabEditor()
                        }
                    )
                    .frame(height: 22)
                    Button("Add", action: submit)
                        .buttonStyle(.pointing)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("new-tab-submit-\(kind.rawValue)")
                }
                .padding(.horizontal, 4)
                .frame(height: 28)
                .onExitCommand {
                    draft = ""
                    workspace.cancelNewTabEditor()
                }
            } else if sites.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else if kind == .favorite {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(sites) { site in
                        SavedSiteTile(site: site, kind: kind)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(sites) { site in
                        SavedSiteChip(site: site)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 640, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.38))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-tab-\(kind.rawValue)s")
    }

    private func submit() {
        if workspace.submitNewTabSite(draft) { draft = "" }
    }
}

private struct SavedSiteTile: View {
    @Environment(Workspace.self) private var workspace
    var site: SavedSite
    var kind: SavedSiteKind

    var body: some View {
        Button { workspace.openPage(site.url) } label: {
            VStack(spacing: 8) {
                Text(letter)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(site.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 72)
            }
            .foregroundStyle(Color.white.opacity(0.94))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel(site.title)
        .accessibilityIdentifier("saved-site-\(site.id.uuidString)")
        .contextMenu {
            Button("Remove") { workspace.savedSites.remove(site.id, from: kind) }
        }
        .help(site.url)
    }

    private var letter: String {
        let scalar = site.title.unicodeScalars.first { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        return scalar.map { String($0).uppercased() } ?? "#"
    }
}

private struct SavedSiteChip: View {
    @Environment(Workspace.self) private var workspace
    var site: SavedSite

    var body: some View {
        Button { workspace.openPage(site.url) } label: {
            Text(site.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.white.opacity(0.94))
                .contentShape(Capsule())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel(site.title)
        .accessibilityIdentifier("saved-site-\(site.id.uuidString)")
        .contextMenu {
            Button("Remove") { workspace.savedSites.remove(site.id, from: .bookmark) }
        }
        .help(site.url)
    }
}
