import AppKit
import SwiftUI

/// The browser's menu for the page. A compact centered pill: a few destinations,
/// and search when the site has one. The site name stays on the page handle.
struct SiteMenuBar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    var available: CGSize
    @State private var searchDraft = ""

    private var menu: SiteMenu? { workspace.siteMenu }
    /// Room for the page actions on the right, matched on the left so the pill stays centered.
    private var maxWidth: CGFloat { max(220, available.width - 320) }
    private var expanded: SiteMenuItem? {
        guard let id = workspace.siteMenuExpanded, id != SiteMenuItem.moreID else { return nil }
        return menu?.items.first { $0.id == id }
    }
    private var showingMore: Bool { workspace.siteMenuExpanded == SiteMenuItem.moreID }

    var body: some View {
        if let menu, showsBar(menu) {
            Group {
                if let item = expanded {
                    submenuRow(item, menu)
                } else if showingMore {
                    moreRow(menu)
                } else {
                    topRow(menu)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .frame(height: 44)
            .foregroundStyle(palette.text)
            .modifier(PageGlass(radius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("site-menu")
            .modifier(SiteMenuExit())
            .animation(reduceMotion ? nil : Metrics.morph, value: workspace.siteMenuExpanded)
            .onChange(of: menu.home) { _, _ in searchDraft = "" }
        }
    }

    private func showsBar(_ menu: SiteMenu) -> Bool {
        if menu.search != nil || expanded != nil || showingMore { return true }
        return menu.items.contains { !$0.label.isEmpty }
    }

    private func split(_ menu: SiteMenu) -> (visible: [SiteMenuItem], extra: [SiteMenuItem]) {
        let items = menu.items.filter { !$0.label.isEmpty }
        let search: CGFloat = menu.search == nil ? 0 : 148
        let budget = max(0, maxWidth - search - 8)
        let widths = items.map { textWidth($0.label, size: 12, weight: .medium) + 16 }
        let count = SiteMenuLayout.visibleCount(itemWidths: widths, budget: budget)
        return (Array(items.prefix(count)), Array(items.dropFirst(count)))
    }

    private func topRow(_ menu: SiteMenu) -> some View {
        let parts = split(menu)
        return HStack(spacing: 0) {
            ForEach(parts.visible) { itemButton($0) }
            if !parts.extra.isEmpty {
                moreButton
            }
            if let search = menu.search {
                compactSearch(search)
            }
        }
        .padding(.horizontal, 4)
    }

    private func moreRow(_ menu: SiteMenu) -> some View {
        let extra = split(menu).extra
        return HStack(spacing: 0) {
            backButton
            scrolling(extra, width: itemsWidth(extra))
            if let search = menu.search {
                compactSearch(search)
            }
            closeButton
        }
    }

    private func submenuRow(_ item: SiteMenuItem, _ menu: SiteMenu) -> some View {
        HStack(spacing: 0) {
            backButton
            Text(item.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.trailing, 8)
            scrolling(item.children, width: itemsWidth(item.children))
            if let search = menu.search {
                compactSearch(search)
            }
            closeButton
        }
    }

    private func scrolling(_ items: [SiteMenuItem], width: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(items) { itemButton($0) }
            }
        }
        .frame(width: min(width, max(80, maxWidth - 120)))
    }

    private func itemsWidth(_ items: [SiteMenuItem]) -> CGFloat {
        items.reduce(0) { $0 + textWidth($1.label, size: 12, weight: .medium) + 16 }
    }

    private var moreButton: some View {
        Button { workspace.siteMenuExpanded = SiteMenuItem.moreID } label: {
            Text("More")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textDim)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel("More")
        .accessibilityIdentifier("site-menu-more")
    }

    private var backButton: some View {
        Button { workspace.collapseSiteMenuChrome() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel("Back")
    }

    private var closeButton: some View {
        Button { workspace.collapseSiteMenuChrome() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("site-menu-close")
    }

    private func compactSearch(_ search: SiteMenuSearch) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textDim)
            WorkInput(
                text: $searchDraft,
                placeholder: "Search",
                identifier: "site-menu-search",
                fontSize: 12,
                palette: palette,
                submit: { workspace.submitSiteSearch(searchDraft) },
                cancel: { searchDraft = "" },
                autofocus: false
            )
            .frame(width: 96, height: 22)
        }
        .padding(.horizontal, 8)
        .frame(width: 132, height: 28)
        .background(palette.hover, in: Capsule())
        .padding(.leading, 6)
        .accessibilityLabel("Search")
    }

    private func itemButton(_ item: SiteMenuItem) -> some View {
        Button { workspace.activateSiteMenuItem(item) } label: {
            Text(item.label)
                .font(.system(size: 12, weight: item.current ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 44)
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

/// Escape closes a morphed destination list. The resting bar stays; it is the browser's menu.
private struct SiteMenuExit: ViewModifier {
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        if workspace.siteMenuExpanded != nil {
            content.onExitCommand { workspace.collapseSiteMenuChrome() }
        } else {
            content
        }
    }
}
