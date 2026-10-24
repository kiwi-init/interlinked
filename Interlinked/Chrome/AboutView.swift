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
                    Text(version).foregroundStyle(.primary)
                }
            }
            Text("A browser that uses AI for useful page labels, search, and safer decisions. You stay in control of when those tools run and what they can read.")
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }

    private var safetyAndPrivacy: some View {
        aboutSection("Safety and privacy") {
            statement("What AI receives", "Meaning search sends your query and extracted page text to Jev. Optional label refinement gives Apple Intelligence page titles, headings, site, host, summary, and breadcrumbs; it returns one label and a short description, cached on this Mac. Related tabs send those local descriptions to Jev. Models return supplied candidate IDs, not executable page code.")

            statement("What stays out", "Interlinked excludes forms and form values, password fields, editable pages, cookies, and local pages from AI reading tools. It does not try to detect whether you are signed in: sharing a signed-in page sends what that page shows. Ordinary browsing, exact find, and deterministic page labels do not use an AI model.")

            statement("Where requests go", JevRuntime.includesJev
                ? "Apple Intelligence requests use Apple's on-device Foundation Models framework and do not go through Interlinked's relay. Jev requests go to the relay, which verifies the App Store-signed copy of the app before forwarding cache misses to OpenRouter for TypeSafe's Jev 1.13 model. Interlinked does not put its OpenRouter key in the app."
                : "Apple Intelligence requests use Apple's on-device Foundation Models framework. Jev requests go directly to OpenRouter for TypeSafe's Jev 1.13 model using the key you supplied. Every Jev request sets OpenRouter's data_collection field to deny.")

            statement("Safer navigation", "Deterministic checks can block active-content URLs or warn about credentials, HTTPS downgrades, encoded hostnames, unusual ports, cross-site forms, and misleading link text. For misleading link text, mixed-script or encoded hostnames, and embedded credentials, Apple Intelligence may paraphrase those facts in one sentence. It cannot name a new threat or override an allow, warning, or block decision. URL paths, queries, fragments, and credentials are omitted.")

            statement("Five-day AI cache", "Interlinked stores a hash of each exact Jev request and its response on this Mac for up to five days. It also caches Apple-generated labels and page descriptions keyed by host, path, and the metadata Apple saw. Neither cache stores page text, queries, credentials, or raw URLs as lookup keys. Changed page text and model versions produce a different key.")

            statement("Data on this Mac", (JevRuntime.includesJev ? "This build does not need or store an OpenRouter key." : "Your OpenRouter key is stored in macOS Keychain.") + " Browser history stays for \(HistoryRetention.standard.days) days in a local file readable only by your macOS account, and you can turn it off in Settings.")

            statement("Your controls", "Settings can turn Jev off, disable AI page labels, clear the five-day AI cache, revoke site grants, and revoke saved navigation exceptions. Local builds that use a personal OpenRouter key can also remove it. A visit grant ends when you quit. A remembered grant stays until you revoke it. Navigating or reloading ends a page-sharing session for that load and cancels stale results.")

            Text("AI matches can be wrong. Read the highlighted source text and decide for yourself.")
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
            Text(detail).foregroundStyle(.primary)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(release)" : "Version \(release) (\(build))"
    }
}
