import SwiftUI

/// Find an open page by its title, address, or preview.
struct WorkspaceOverview: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette
    @State private var query = ""

    private var matches: [Tab] {
        workspace.tabs.filter { tab in
            OpenWork.matches(query, title: workspace.title(tab), details: tab.root.leaves().flatMap {
                [workspace.surfaces.line($0), workspace.hosts.titles[$0] ?? ""]
            })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkInput(text: $query, placeholder: "Find a page or search…",
                      identifier: "workspace-search", fontSize: 16, palette: palette,
                      submit: submit, cancel: { workspace.setOverviewOpen(false) })
                .frame(height: 24)
            ScrollView {
                if !workspace.assistance.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Related pages").font(.system(size: 10)).foregroundStyle(palette.textDim)
                        ForEach(workspace.assistance.groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                HStack {
                                    ForEach(group.members, id: \.self) { id in
                                        if let tab = workspace.tabs.first(where: { String($0.id.rawValue) == id }) {
                                            Button { workspace.selectWork(tab.id) } label: {
                                                SiteIcon(pane: tab.active, palette: palette)
                                            }.buttonStyle(.plain).help(workspace.title(tab))
                                        }
                                    }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 190), spacing: 10)], spacing: 10) {
                    ForEach(matches) { tab in
                        Button { workspace.selectWork(tab.id) } label: {
                            workCard(tab)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(workspace.title(tab)), \(workspace.surfaces.tabTitle(tab))")
                        .accessibilityIdentifier("work-tab-\(tab.id.rawValue)")
                        .contextMenu {
                            Button("Rename") { _ = workspace.editTab(tab.id) }
                            Button("Close Tab") { workspace.closeTab(tab.id) }
                        }
                    }

                }
                .padding(2)
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { workspace.openAddress(query) } label: {
                        Text(navigationURL(from: query) == nil ? "Search Google for \"\(query)\"  ↵" : "Open \(query)  ↵")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace-open-query")
                }
            }
            HStack {
                Button("New page  ⌘T") { workspace.newPage() }
                    .buttonStyle(.plain)
                Spacer()
                Text("Esc to return")
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.textDim)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(palette.text)
        .onExitCommand { workspace.setOverviewOpen(false) }
    }

    private func workCard(_ tab: Tab) -> some View {
        VStack(spacing: 0) {
            PagePreview(pane: tab.active, palette: palette)
                .frame(height: 84)
                .clipped()
            cardLabel(pane: tab.active, title: workspace.title(tab), detail: detail(tab))
        }
        .background(palette.pane)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func detail(_ tab: Tab) -> String {
        let domain = workspace.surfaces.kind(tab.active).compactLabel(for: workspace.surfaces.line(tab.active))
        return domain
    }

    private func cardLabel(pane: PaneID?, title: String, detail: String) -> some View {
        HStack(spacing: 6) {
            SiteIcon(pane: pane, palette: palette)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.textDim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(height: 48)
        .background(palette.hover)
    }

    private func submit() {
        if let tab = matches.first { workspace.selectWork(tab.id) }
        else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { workspace.openAddress(query) }
    }
}

private struct PagePreview: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID
    var palette: Palette

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                palette.pane
                if let image = workspace.hosts.previews[pane] {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .clipped()
                } else {
                    VStack(spacing: 12) {
                        SiteIcon(pane: pane, palette: palette)
                        Text(workspace.surfaces.kind(pane).compactLabel(for: workspace.surfaces.line(pane)))
                            .font(.system(size: 12)).lineLimit(1)
                    }
                }
            }
        }
    }
}
