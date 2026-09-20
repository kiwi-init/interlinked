import SwiftUI

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Interlinked") { openWindow(id: "about") }
        }
    }
}

struct AboutView: View {
    private let columnWidth: CGFloat = 680

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                criticalReading
                safetyAndPrivacy
            }
            .frame(maxWidth: columnWidth, alignment: .leading)
            .padding(32)
        }
        .frame(width: 744, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 32, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interlinked").font(.title.bold())
                    Text(version).foregroundStyle(.secondary)
                }
            }
            Text("A browser that uses AI for reading assistance, useful page labels, search, and safer decisions. You stay in control of when those tools run and what they can read.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var criticalReading: some View {
        aboutSection("Critical Reading, in full") {
            Text("Critical Reading is an anti-bias aid, not a fact checker. It sends each readable passage to Jev 1.13 and asks for one fixed classification. The model receives this exact shared instruction, followed by the passage's internal source ID:")

            copyable(PassageDecisions.classificationInstruction)

            Text("These are the exact choices and definitions sent with every passage:")

            VStack(alignment: .leading, spacing: 12) {
                ForEach(PassageDecisions.Signal.allCases, id: \.rawValue) { signal in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(signal.label).fontWeight(.semibold)
                            Spacer()
                            Text(signal.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(signal.explanation).foregroundStyle(.secondary)
                    }
                    if signal != PassageDecisions.Signal.allCases.last { Divider() }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

            Text("When Jev supplies choice probabilities, Interlinked requires at least \(Int(PassageDecisions.displaySignalProbability * 100))% combined probability that a real signal exists and at least \(Int(PassageDecisions.displayCategoryProbability * 100))% for the displayed classification. If probabilities are absent, it requires \(Int(PassageDecisions.displayConfidence * 100))% confidence. Fragments shorter than \(PassageDecisions.minimumSubstantiveWords) words are not sent or highlighted. Long passages are limited to \(PassageDecisions.readingTextLimit) characters for classification, and long pages are processed in batches of \(PassageDecisions.readingBatchSize). \"No clear signal\" and \"Uncertain\" are never highlighted. A \"Probably AI-generated\" result is a pattern-based guess, not proof of authorship. The check does not verify facts or infer whether a writer intended to mislead.")
                .font(.callout)
        }
    }

    private var safetyAndPrivacy: some View {
        aboutSection("Safety and privacy") {
            statement("What AI receives", "Critical Reading sends readable text from public pages to Jev. Meaning search sends your query and extracted page text to Jev. Vault search gives Apple Intelligence the query and up to six locally saved candidates first; a Jev fallback can receive the query and relevant excerpts from up to 24 saved pages. Optional label refinement gives Apple Intelligence page titles, descriptions, and locally generated label choices, with the same limited evidence used for a Jev fallback. Personal Filters first try an exact local match; when that is not enough, they send the filter description with addressable text ranges, page elements, controls, and media labels to Jev. Models return supplied candidate IDs, not executable page code.")

            statement("What stays out", "Interlinked excludes forms and form values, password fields, editable pages, cookies, and local pages from AI reading tools. Critical Reading does not send the page URL. Ordinary browsing, exact find, deterministic page labels, and Vault storage do not use an AI model.")

            statement("Where requests go", JevRuntime.includesJev
                ? "Apple Intelligence requests use Apple's on-device Foundation Models framework and do not go through Interlinked's relay. Jev requests go to the relay, which verifies the App Store-signed copy of the app before forwarding cache misses to OpenRouter for TypeSafe's Jev 1.13 model. Interlinked does not put its OpenRouter key in the app."
                : "Apple Intelligence requests use Apple's on-device Foundation Models framework. Jev requests go directly to OpenRouter for TypeSafe's Jev 1.13 model using the key you supplied. Every Jev request sets OpenRouter's data_collection field to deny.")

            statement("Safer navigation", "WebKit's fraudulent-site warning stays enabled. Before suspicious navigation, deterministic checks can block active-content URLs or warn about credentials, HTTPS downgrades, encoded hostnames, unusual ports, cross-site forms, and misleading link text. Apple Intelligence may add a short explanation using only sanitized source and destination origins, visible link text, and those warning facts. It cannot override an allow, warning, or block decision. URL paths, queries, fragments, and credentials are omitted.")

            statement("Five-day AI cache", "Interlinked stores a hash of each exact Jev request and its response on this Mac for up to five days. It does not store page text, queries, URLs, or credentials in this cache. Changed page text, model versions, and classification rules produce a different hash and cannot reuse an older result.")

            statement("Data on this Mac", (JevRuntime.includesJev ? "This build does not need or store an OpenRouter key. " : "Your OpenRouter key is stored in macOS Keychain. ") + "Vault pages are saved only when you choose the Vault button, in a local file readable only by your macOS account. Vault stores the URL and extracted text, not screenshots, cookies, or form contents. Personal Filter descriptions are stored in a separate local file readable only by your macOS account and are scoped to the website where you created them.")

            statement("Your controls", "Settings can turn Jev off, run Critical Reading only when asked, disable AI page labels, clear the five-day AI cache, clear the Vault, and revoke saved navigation exceptions. Each Personal Filter can be paused or deleted from its own panel. Local builds that use a personal OpenRouter key can also remove it. Navigating or reloading ends a page-sharing grant and cancels stale results.")

            Text("AI classifications can be wrong. Read the highlighted source text and decide for yourself.")
                .font(.callout.weight(.semibold))
        }
    }

    private func aboutSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            content()
        }
        .textSelection(.enabled)
    }

    private func statement(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.semibold)
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func copyable(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(release)" : "Version \(release) (\(build))"
    }
}
