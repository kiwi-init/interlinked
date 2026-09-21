import AppKit
import SwiftUI

/// The browser's menu for the page, built like the page handle: one continuous
/// glass shape whose size morphs between destinations, a submenu, and search,
/// with the contents crossfading inside it. The site name stays on the handle.
struct SiteMenuBar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    var available: CGSize
    @State private var searchDraft = ""

    /// What the pill is currently shaped around.
    private enum Mode: Equatable {
        case destinations
        case more
        case submenu(String)
        case search
    }

    private static let radius: CGFloat = 14
    private static let rowHeight: CGFloat = 44
    private static let chevronWidth: CGFloat = 44
    private static let searchIconWidth: CGFloat = 44
    private static let moreWidth: CGFloat = 64
    private static let labelSize: CGFloat = 13
    private static let glyphSize: CGFloat = 13
    private static let searchWidth: CGFloat = 320

    private var menu: SiteMenu? { workspace.siteMenu }
    /// Room for the page actions on the right, matched on the left so the pill stays centered.
    private var maxWidth: CGFloat { max(220, available.width - 320) }

    var body: some View {
        if let menu, showsBar(menu) {
            let mode = resolved(menu)
            let size = CGSize(width: width(mode, menu), height: Self.rowHeight)
            ZStack {
                switch mode {
                case .search:
                    if let search = menu.search { searchRow(search).transition(.opacity) }
                case .submenu(let id):
                    if let item = menu.items.first(where: { $0.id == id }) {
                        submenuRow(item, menu).transition(.opacity)
                    }
                case .more:
                    moreRow(menu).transition(.opacity)
                case .destinations:
                    topRow(menu).transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .modifier(PageGlass(radius: Self.radius))
            .modifier(AILabelGlow(effect: workspace.siteMenuEffect, pane: workspace.activePane,
                                  radius: Self.radius))
            .foregroundStyle(palette.text)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("site-menu")
            .modifier(SiteMenuExit())
            .animation(reduceMotion ? nil : Metrics.morph, value: size)
            .animation(reduceMotion ? nil : Metrics.morph, value: mode)
            .onChange(of: menu.home) { _, _ in searchDraft = "" }
        }
    }

    private func showsBar(_ menu: SiteMenu) -> Bool {
        if menu.search != nil || workspace.siteMenuExpanded != nil { return true }
        return menu.items.contains { !$0.label.isEmpty }
    }

    // MARK: - Shape

    /// The requested mode, dropped back to the destinations when the page no
    /// longer offers what it asked for.
    private func resolved(_ menu: SiteMenu) -> Mode {
        if workspace.siteMenuSearching {
            return menu.search == nil ? .destinations : .search
        }
        guard let id = workspace.siteMenuExpanded else { return .destinations }
        if id == SiteMenuItem.moreID {
            return split(menu).extra.isEmpty ? .destinations : .more
        }
        return menu.items.contains { $0.id == id } ? .submenu(id) : .destinations
    }

    private func width(_ mode: Mode, _ menu: SiteMenu) -> CGFloat {
        let search: CGFloat = menu.search == nil ? 0 : Self.searchIconWidth
        switch mode {
        case .destinations:
            let parts = split(menu)
            let items = parts.visible.reduce(0) { $0 + itemWidth($1) }
            return min(maxWidth, items + (parts.extra.isEmpty ? 0 : Self.moreWidth) + search + 8)
        case .more:
            let extra = split(menu).extra
            return min(maxWidth, Self.chevronWidth + scrollWidth(extra) + search + Self.chevronWidth)
        case .submenu(let id):
            let item = menu.items.first { $0.id == id }
            let label = item.map { textWidth($0.label, size: Self.labelSize, weight: .semibold) + 12 } ?? 0
            return min(maxWidth, Self.chevronWidth + label + scrollWidth(item?.children ?? [])
                       + search + Self.chevronWidth)
        case .search:
            return min(maxWidth, Self.searchWidth)
        }
    }

    private func split(_ menu: SiteMenu) -> (visible: [SiteMenuItem], extra: [SiteMenuItem]) {
        let items = menu.items.filter { !$0.label.isEmpty }
        let search: CGFloat = menu.search == nil ? 0 : Self.searchIconWidth
        let budget = max(0, maxWidth - search - 8)
        let count = SiteMenuLayout.visibleCount(itemWidths: items.map(itemWidth), budget: budget,
                                                moreWidth: Self.moreWidth)
        return (Array(items.prefix(count)), Array(items.dropFirst(count)))
    }

    private func itemWidth(_ item: SiteMenuItem) -> CGFloat {
        max(Self.rowHeight, textWidth(item.label, size: Self.labelSize, weight: .semibold) + 24)
    }

    private func itemsWidth(_ items: [SiteMenuItem]) -> CGFloat {
        items.reduce(0) { $0 + itemWidth($1) }
    }

    private func scrollWidth(_ items: [SiteMenuItem]) -> CGFloat {
        min(itemsWidth(items), max(80, maxWidth - 120))
    }

    // MARK: - Rows

    private func topRow(_ menu: SiteMenu) -> some View {
        let parts = split(menu)
        return HStack(spacing: 0) {
            ForEach(parts.visible) { itemButton($0) }
            if !parts.extra.isEmpty {
                moreButton
            }
            if menu.search != nil {
                searchButton
            }
        }
        .padding(.horizontal, 6)
    }

    private func moreRow(_ menu: SiteMenu) -> some View {
        let extra = split(menu).extra
        return HStack(spacing: 0) {
            backButton
            scrolling(extra)
            if menu.search != nil {
                searchButton
            }
            closeButton
        }
    }

    private func submenuRow(_ item: SiteMenuItem, _ menu: SiteMenu) -> some View {
        HStack(spacing: 0) {
            backButton
            Text(item.label)
                .font(.system(size: Self.labelSize, weight: .semibold))
                .lineLimit(1)
                .padding(.trailing, 12)
            scrolling(item.children)
            if menu.search != nil {
                searchButton
            }
            closeButton
        }
    }

    /// Morphed state: the same pill, now a field. Escape or Close returns it.
    private func searchRow(_ search: SiteMenuSearch) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Self.glyphSize, weight: .medium))
                .foregroundStyle(palette.textDim)
                .padding(.leading, 16)
            WorkInput(
                text: $searchDraft,
                placeholder: search.placeholder.isEmpty ? "Search" : search.placeholder,
                identifier: "site-menu-search",
                fontSize: Self.labelSize,
                palette: palette,
                submit: { workspace.submitSiteSearch(searchDraft) },
                cancel: { workspace.collapseSiteMenuChrome() },
                autofocus: true
            )
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            closeButton
        }
    }

    private func scrolling(_ items: [SiteMenuItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(items) { itemButton($0) }
            }
        }
        .frame(width: scrollWidth(items))
    }

    // MARK: - Controls

    private var moreButton: some View {
        Button { workspace.siteMenuExpanded = SiteMenuItem.moreID } label: {
            Text("More")
                .font(.system(size: Self.labelSize, weight: .medium))
                .foregroundStyle(palette.textDim)
                .frame(width: Self.moreWidth, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel("More")
        .accessibilityIdentifier("site-menu-more")
    }

    private var backButton: some View {
        Button { workspace.collapseSiteMenuChrome() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: Self.glyphSize, weight: .medium))
                .frame(width: Self.chevronWidth, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel("Back")
    }

    private var closeButton: some View {
        Button { workspace.collapseSiteMenuChrome() } label: {
            Image(systemName: "xmark")
                .font(.system(size: Self.glyphSize, weight: .medium))
                .frame(width: Self.chevronWidth, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("site-menu-close")
    }

    /// Resting state: search is one glyph beside the destinations.
    private var searchButton: some View {
        Button { workspace.beginSiteMenuSearch() } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Self.glyphSize, weight: .medium))
                .foregroundStyle(palette.textDim)
                .frame(width: Self.searchIconWidth, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel("Search this site")
        .accessibilityIdentifier("site-menu-search-button")
    }

    private func itemButton(_ item: SiteMenuItem) -> some View {
        Button { workspace.activateSiteMenuItem(item) } label: {
            Text(item.label)
                .font(.system(size: Self.labelSize, weight: item.current ? .semibold : .medium))
                .lineLimit(1)
                .frame(width: itemWidth(item), height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel(item.title.isEmpty ? item.label : item.title)
        .help(item.title.isEmpty ? item.label : item.title)
    }

    private func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }
}

/// Escape closes a morphed destination list or search field. The resting bar
/// stays; it is the browser's menu.
private struct SiteMenuExit: ViewModifier {
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        if workspace.siteMenuExpanded != nil || workspace.siteMenuSearching {
            content.onExitCommand { workspace.collapseSiteMenuChrome() }
        } else {
            content
        }
    }
}
