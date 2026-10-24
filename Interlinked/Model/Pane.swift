import AppKit

struct PageURLCopyShortcut {
    static func matches(
        character: String?,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        function: Bool
    ) -> Bool {
        character?.lowercased() == "c" && command && shift && !option && !control && !function
    }
}

enum CopiedPageURLFeedback {
    /// Optional strings compare equal when both are nil, so a new tab would
    /// otherwise show "Copied" without a copy ever happening.
    static func isShowing(copied: String?, current: String?) -> Bool {
        guard let copied, let current else { return false }
        return copied == current
    }
}

enum NewTabPage {
    static func matches(line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ToolboxShortcut: Equatable {
    case find
    case sharingScreen
    case settings

    var label: String {
        switch self {
        case .find: "⌘F"
        case .sharingScreen: "⇧⌘S"
        case .settings: "⌘,"
        }
    }
}

enum TabClosingPolicy {
    static func opensReplacementTab(remainingTabCount: Int) -> Bool {
        remainingTabCount == 0
    }
}

struct PaneID: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    var rawValue: UInt64
    init(_ raw: UInt64) { rawValue = raw }
    init(rawValue: UInt64) { self.rawValue = rawValue }
    var description: String { String(rawValue) }
}

struct TabID: Hashable, Codable, RawRepresentable {
    var rawValue: UInt64
    init(_ raw: UInt64) { rawValue = raw }
    init(rawValue: UInt64) { self.rawValue = rawValue }
}

struct SplitID: Hashable, Codable, RawRepresentable {
    var rawValue: UInt64
    init(_ raw: UInt64) { rawValue = raw }
    init(rawValue: UInt64) { self.rawValue = rawValue }
}

enum SplitAxis: String, Codable, Equatable {
    case columns
    case rows
}

enum Side: String, Equatable {
    case left, right, up, down

    static func parse(_ word: String) -> Side? {
        switch word.lowercased() {
        case "left": return .left
        case "right": return .right
        case "up", "above", "over": return .up
        case "down", "below", "under", "beneath": return .down
        default: return nil
        }
    }
}

/// A tab is a grid: one split across, one split down, at most four panes.
indirect enum Pane: Equatable {
    case leaf(PaneID)
    case split(id: SplitID, axis: SplitAxis, first: Pane, second: Pane)

    static let maxPanes = 4
    static let half: Float = 0.5

    var isLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }

    func isLeaf(_ id: PaneID) -> Bool {
        if case .leaf(let leaf) = self { return leaf == id }
        return false
    }

    func contains(_ id: PaneID) -> Bool {
        switch self {
        case .leaf(let leaf): return leaf == id
        case .split(_, _, let first, let second): return first.contains(id) || second.contains(id)
        }
    }

    func firstLeaf() -> PaneID {
        switch self {
        case .leaf(let id): return id
        case .split(_, _, let first, _): return first.firstLeaf()
        }
    }

    func leaves() -> [PaneID] {
        var ids: [PaneID] = []
        collectLeaves(&ids)
        return ids
    }

    private func collectLeaves(_ ids: inout [PaneID]) {
        switch self {
        case .leaf(let id): ids.append(id)
        case .split(_, _, let first, let second):
            first.collectLeaves(&ids)
            second.collectLeaves(&ids)
        }
    }

    func canSplit(_ target: PaneID, axis: SplitAxis) -> Bool {
        leaves().count < Self.maxPanes && (axisAround(target).map { $0 != axis } ?? true)
    }

    private func axisAround(_ target: PaneID) -> SplitAxis? {
        guard case .split(_, let axis, let first, let second) = self else { return nil }
        if first.isLeaf(target) || second.isLeaf(target) { return axis }
        if first.contains(target) { return first.axisAround(target) }
        if second.contains(target) { return second.axisAround(target) }
        return nil
    }

    @discardableResult
    mutating func split(_ target: PaneID, axis: SplitAxis, new: PaneID, id: SplitID) -> Bool {
        guard canSplit(target, axis: axis) else { return false }
        switch self {
        case .leaf(let leaf) where leaf == target:
            self = .split(id: id, axis: axis, first: .leaf(target), second: .leaf(new))
            return true
        case .leaf:
            return false
        case .split(let splitID, let splitAxis, var first, var second):
            if first.split(target, axis: axis, new: new, id: id) {
                self = .split(id: splitID, axis: splitAxis, first: first, second: second)
                return true
            }
            if second.split(target, axis: axis, new: new, id: id) {
                self = .split(id: splitID, axis: splitAxis, first: first, second: second)
                return true
            }
            return false
        }
    }

    func coordinate(_ target: PaneID) -> (Int, Int) {
        var coordinate = (0, 0)
        collectCoordinate(target, &coordinate)
        return coordinate
    }

    private func collectCoordinate(_ target: PaneID, _ coordinate: inout (Int, Int)) {
        guard case .split(_, let axis, let first, let second) = self else { return }
        if first.contains(target) {
            first.collectCoordinate(target, &coordinate)
        } else if second.contains(target) {
            switch axis {
            case .rows: coordinate.0 += 1
            case .columns: coordinate.1 += 1
            }
            second.collectCoordinate(target, &coordinate)
        }
    }

    func neighbour(_ target: PaneID, _ side: Side) -> PaneID? {
        let (row, column) = coordinate(target)
        var best: (Int, Int, UInt64)?
        for leaf in leaves() where leaf != target {
            let (leafRow, leafColumn) = coordinate(leaf)
            let towards: Int
            let across: Int
            switch side {
            case .left:
                guard column > leafColumn else { continue }
                towards = column - leafColumn
                across = abs(leafRow - row)
            case .right:
                guard leafColumn > column else { continue }
                towards = leafColumn - column
                across = abs(leafRow - row)
            case .up:
                guard row > leafRow else { continue }
                towards = row - leafRow
                across = abs(leafColumn - column)
            case .down:
                guard leafRow > row else { continue }
                towards = leafRow - row
                across = abs(leafColumn - column)
            }
            guard towards > 0 else { continue }
            let candidate = (towards, across, leaf.rawValue)
            if best == nil || candidate < best! {
                best = candidate
            }
        }
        return best.map { PaneID($0.2) }
    }

    /// Puts `new` where `old` was. `new` must not already be in the tree.
    @discardableResult
    mutating func replace(_ old: PaneID, with new: PaneID) -> Bool {
        guard contains(old), !contains(new) else { return false }
        swapLeaves(old, new)
        return true
    }

    @discardableResult
    mutating func swap(_ a: PaneID, _ b: PaneID) -> Bool {
        if a == b { return contains(a) }
        guard contains(a), contains(b) else { return false }
        swapLeaves(a, b)
        return true
    }

    private mutating func swapLeaves(_ a: PaneID, _ b: PaneID) {
        switch self {
        case .leaf(let id):
            if id == a { self = .leaf(b) }
            else if id == b { self = .leaf(a) }
        case .split(let id, let axis, var first, var second):
            first.swapLeaves(a, b)
            second.swapLeaves(a, b)
            self = .split(id: id, axis: axis, first: first, second: second)
        }
    }

    /// Collapses the split that held `target`. Returns the pane that should take
    /// focus, or nil if this is a single leaf (the caller should close the tab).
    @discardableResult
    mutating func close(_ target: PaneID) -> PaneID? {
        guard case .split(let id, let axis, var first, var second) = self else { return nil }
        if first.isLeaf(target) {
            self = second
            return firstLeaf()
        }
        if second.isLeaf(target) {
            self = first
            return firstLeaf()
        }
        if let focus = first.close(target) {
            self = .split(id: id, axis: axis, first: first, second: second)
            return focus
        }
        if let focus = second.close(target) {
            self = .split(id: id, axis: axis, first: first, second: second)
            return focus
        }
        return nil
    }
}

extension Pane: Codable {
    enum CodingKeys: String, CodingKey {
        case leaf, split
    }

    struct SplitBody: Codable {
        var id: SplitID
        var axis: SplitAxis
        var first: Pane
        var second: Pane
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(UInt64.self, forKey: .leaf) {
            self = .leaf(PaneID(raw))
            return
        }
        let body = try container.decode(SplitBody.self, forKey: .split)
        self = .split(id: body.id, axis: body.axis, first: body.first, second: body.second)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try container.encode(id.rawValue, forKey: .leaf)
        case .split(let id, let axis, let first, let second):
            try container.encode(SplitBody(id: id, axis: axis, first: first, second: second), forKey: .split)
        }
    }
}

struct Tab: Codable, Equatable, Identifiable {
    /// Split view shows two pages side by side, never more.
    static let maxPanes = 2

    var id: TabID
    var root: Pane
    var active: PaneID
    var name: String?
    /// The first page's share of the width in split view. Nil is half.
    var ratio: Double?

    static let ratioRange = 0.2...0.8

    var panes: [PaneID] { root.leaves() }
    var splitRatio: Double {
        guard let ratio, ratio.isFinite else { return 0.5 }
        return min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
    }
    var isSplit: Bool { panes.count > 1 }
    var canSplit: Bool { panes.count < Self.maxPanes }
    /// The pane beside the focused one in split view.
    var otherPane: PaneID? { panes.first { $0 != active } }

    init(id: TabID, pane: PaneID) {
        self.id = id
        self.root = .leaf(pane)
        self.active = pane
        self.name = nil
    }

    func contains(_ pane: PaneID) -> Bool { root.contains(pane) }

    @discardableResult
    mutating func split(_ target: PaneID, axis: SplitAxis, new: PaneID, id: SplitID) -> Bool {
        guard canSplit else { return false }
        if root.split(target, axis: axis, new: new, id: id) {
            active = new
            return true
        }
        return false
    }

    @discardableResult
    mutating func close(_ target: PaneID) -> Bool {
        if let focus = root.close(target) {
            active = focus
            if !isSplit { ratio = nil }
            return true
        }
        return false
    }
}
