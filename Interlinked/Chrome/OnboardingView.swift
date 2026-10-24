import AppKit
import SwiftUI

/// The Onboarding tab. Each scene asks for one small thing, and its checklist
/// fills in as the browser sees you do it.
struct OnboardingView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette

    /// The scene on screen. It trails the real one briefly so the last
    /// checkmark of a finished scene is seen before the next one arrives.
    @State private var shown: OnboardingScene?
    /// The pane's width. Beside a real page it is narrow, and the type follows.
    @State private var width: CGFloat = 1000
    private var compact: Bool { width < 620 }

    private var guide: OnboardingGuide { workspace.onboarding }
    private var scene: OnboardingScene { shown ?? guide.progress.scene }
    /// The page speaks only about steps done on it; the rest is the coach's.
    private var pagePart: OnboardingPart {
        let current = scene.current(guide.progress)
        return current.onPage ? current : (scene.revealed(guide.progress).last { $0.onPage } ?? current)
    }

    var body: some View {
        ZStack {
            palette.pane

            VStack(spacing: 28) {
                SceneDots(current: scene.id, palette: palette)
                VStack(spacing: 16) {
                    if let title = scene.title {
                        Text(title)
                            .font(.system(size: compact ? 28 : 40, weight: .regular, design: .serif))
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(scene.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.system(size: scene.smallPrint ? (compact ? 11 : 12) : (compact ? 13 : 15)))
                            .foregroundStyle(palette.textDim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if scene.features.isEmpty {
                        OnboardingInstruction(parts: pagePart.instruction, palette: palette, size: compact ? 15 : 17)
                            .id(pagePart.step)
                            .transition(.opacity)
                    }
                }
                if !scene.features.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(scene.features, id: \.self) { feature in
                            FeatureCard(feature: feature, palette: palette, compact: compact)
                        }
                    }
                    // Features are optional, so these scenes move on when asked.
                    let step = scene.current(guide.progress).step
                    if !guide.progress.isDone(step) {
                        Button { workspace.advanceOnboarding(step) } label: {
                            HStack(spacing: 8) {
                                Text(step == .finished ? "Start browsing" : "Next")
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, 22)
                            .frame(height: 40)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.pointing)
                        // Outside the button: the glass claims taps on itself, and inside
                        // the label it would take the click away from the button.
                        .modifier(PageGlass(radius: 20))
                        .accessibilityIdentifier("onboarding-next")
                        .transition(.opacity)
                    }
                } else {
                    OnboardingGIF(name: scene.gif)
                    OnboardingChecklist(parts: scene.revealed(guide.progress).filter(\.onPage),
                                        progress: guide.progress, palette: palette)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, compact ? 20 : 40)
            .padding(.bottom, 64)
            .id(scene.id)
            .transition(.opacity)

            VStack {
                Spacer()
                if let notice = guide.notice {
                    Label(notice, systemImage: "hand.raised")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .modifier(PageGlass(radius: 14))
                        .transition(.opacity)
                        .accessibilityIdentifier("onboarding-notice")
                }
                Button("Close onboarding", action: workspace.closeOnboarding)
                    .buttonStyle(.pointing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textDim)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("onboarding-close")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: scene.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: pagePart.step)
        .animation(reduceMotion ? nil : Metrics.morph, value: workspace.usesSiteMenu)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: guide.progress.scene.id) { old, _ in
            shown = OnboardingScene.all.first { $0.id == old }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 1_200))
                shown = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding")
    }
}

/// A feature introduced by a scene: its name, a real switch, and what it does.
private struct FeatureCard: View {
    @Environment(Workspace.self) private var workspace
    var feature: OnboardingFeature
    var palette: Palette
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if let symbol = feature.mark.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 16 : 22, weight: .medium))
                        .foregroundStyle(palette.text)
                        .frame(width: compact ? 20 : 28, height: compact ? 20 : 28)
                        .accessibilityHidden(true)
                } else if let asset = feature.mark.asset, NSImage(named: asset) != nil {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: compact ? 20 : 28, height: compact ? 20 : 28)
                        .accessibilityHidden(true)
                }
                Text(feature.title)
                    .font(.system(size: compact ? 16 : 22, weight: .semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 16)
                Toggle(feature.title, isOn: workspace.binding(for: feature))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(workspace.disables(feature))
                    .pointingHandCursor()
                    .accessibilityIdentifier("onboarding-feature-\(feature.rawValue)")
            }
            Text(feature.summary)
                .font(.system(size: compact ? 12 : 14))
                .foregroundStyle(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let note = workspace.note(for: feature) {
                Label(note, systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.text)
            }
        }
        .padding(compact ? 14 : 20)
        .frame(maxWidth: 520, alignment: .leading)
        .background(palette.hover.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.hairline))
    }
}

private struct SceneDots: View {
    var current: Int
    var palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingScene.all) { scene in
                Capsule()
                    .fill(scene.id == current ? palette.text : palette.textDim.opacity(0.4))
                    .frame(width: scene.id == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current) of \(OnboardingScene.all.count)")
    }
}

/// Words and keycaps that wrap together as one sentence.
struct OnboardingInstruction: View {
    var parts: [OnboardingText]
    var palette: Palette
    var size: CGFloat = 17
    var centered = true

    var body: some View {
        FlowLayout(spacing: size * 0.3, lineSpacing: size * 0.45, centered: centered) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .word(let word):
                    Text(word)
                        .font(.system(size: size))
                        .foregroundStyle(palette.text)
                case .keys(let keys, let trailing):
                    HStack(spacing: 3) {
                        ForEach(keys, id: \.self) { Keycap(key: $0, palette: palette, size: size) }
                        if !trailing.isEmpty {
                            Text(trailing)
                                .font(.system(size: size))
                                .foregroundStyle(palette.text)
                                .padding(.leading, -1)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private enum Token {
        case word(String)
        /// Punctuation right after keys stays with them: "⌘ T," never wraps apart.
        case keys([String], trailing: String)
    }

    /// One token per word, so the sentence can wrap between any two.
    private var tokens: [Token] {
        var tokens: [Token] = []
        for part in parts {
            switch part {
            case .keys(let keys):
                tokens.append(.keys(keys, trailing: ""))
            case .words(let text):
                for word in text.split(separator: " ").map(String.init) {
                    if case .keys(let keys, let trailing)? = tokens.last,
                       word.first.map({ $0.isPunctuation }) == true {
                        tokens[tokens.count - 1] = .keys(keys, trailing: trailing + word)
                    } else {
                        tokens.append(.word(word))
                    }
                }
            }
        }
        return tokens
    }

    private var spoken: String {
        parts.map { part in
            switch part {
            case .words(let text): text
            case .keys(let keys): keys.map { $0 == "⌘" ? "Command" : $0 }.joined(separator: " ")
            }
        }.joined(separator: " ")
    }
}

private struct Keycap: View {
    var key: String
    var palette: Palette
    var size: CGFloat

    var body: some View {
        Text(key)
            .font(.system(size: size * 0.76, weight: .semibold, design: .rounded))
            .foregroundStyle(palette.text)
            .frame(minWidth: size * 1.4, minHeight: size * 1.4)
            .padding(.horizontal, size * 0.28)
            .background(palette.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.hairline))
    }
}

/// Every step of the scene, the icon column aligned, done ones checked.
struct OnboardingChecklist: View {
    var parts: [OnboardingPart]
    var progress: OnboardingProgress
    var palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(parts, id: \.step) { check in
                let done = progress.isDone(check.step)
                let next = progress.next == check.step
                HStack(spacing: 10) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(done ? Color.green : palette.textDim)
                        .frame(width: 20)
                        .contentTransition(.symbolEffect(.replace))
                    Text(check.check)
                        .font(.system(size: 13, weight: next ? .semibold : .regular))
                        .foregroundStyle(done || next ? palette.text : palette.textDim)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(done ? "Done" : "Not done")
                .accessibilityIdentifier("onboarding-check-\(check.step.rawValue)")
            }
        }
        .animation(.easeOut(duration: 0.25), value: progress)
    }
}

/// A recorded demonstration. Takes no space until its file is in the bundle.
private struct OnboardingGIF: View {
    var name: String

    var body: some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "gif"),
           let image = NSImage(contentsOf: url), image.size.width > 0 {
            AnimatedImage(image: image)
                .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                .frame(maxWidth: 560)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// NSImageView plays GIF frames on its own; SwiftUI's Image shows only the first.
private struct AnimatedImage: NSViewRepresentable {
    var image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

/// Lays children out in rows that wrap, centered or from the leading edge.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var centered: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (centered ? (bounds.width - row.width) / 2 : 0)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Follows you onto other pages while onboarding waits for you, so the rest
/// of the instruction and its checklist stay in sight after ⌘T.
struct OnboardingCoach: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette

    private var guide: OnboardingGuide { workspace.onboarding }
    private var visible: Bool { workspace.showsOnboardingCoach }

    var body: some View {
        let scene = guide.progress.scene
        Group {
            if visible {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Workspace.onboardingTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textDim)
                    let current = scene.current(guide.progress)
                    OnboardingInstruction(parts: current.onPage ? scene.away : current.instruction,
                                          palette: palette, size: 14, centered: false)
                    OnboardingChecklist(parts: scene.revealed(guide.progress), progress: guide.progress, palette: palette)
                }
                .padding(16)
                .frame(width: 300, alignment: .leading)
                .modifier(PageGlass(radius: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding-coach")
            }
        }
        .animation(reduceMotion ? nil : Metrics.morph, value: visible)
        .animation(reduceMotion ? nil : Metrics.morph, value: scene.id)
    }
}
