import SwiftUI

/// Input lives inside the growing page handle, with no separate panel or backdrop.
struct LineEditor: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette

    var body: some View {
        WorkInput(text: Binding(
                get: {
                    if let text = workspace.editing?.text { return text }
                    if workspace.isEmptyActivePage { return "" }
                    return workspace.activePane.map { workspace.assistance.label($0, url: workspace.surfaces.line($0)) } ?? ""
                },
                set: {
                    if workspace.editing == nil { workspace.editActiveLine() }
                    workspace.editing?.text = $0
                }
            ), placeholder: workspace.editing?.tab == nil ? "Search or address" : "Tab name",
                      identifier: "line-editor", fontSize: 12, palette: palette,
                      submit: workspace.submitLine,
                      cancel: {
                          workspace.discardLine()
                          workspace.beginEmptyPageEditingIfNeeded()
                      },
                      moveSelection: workspace.moveSearchSelection,
                      autofocus: workspace.editing != nil || (workspace.isEmptyActivePage && !workspace.overviewOpen && !workspace.identityOpen),
                      beginEditing: {
                          if workspace.editing == nil, !workspace.overviewOpen, !workspace.identityOpen {
                              workspace.editActiveLine()
                          }
                      })
            .id(workspace.editing?.target ?? workspace.activePane.map(LineTarget.pane))
            .frame(height: 22)
        .foregroundStyle(palette.text)
        .onExitCommand {
            workspace.discardLine()
            workspace.beginEmptyPageEditingIfNeeded()
        }
    }
}

/// Focus when attached to the window, after the handle's new content exists.
struct WorkInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var identifier: String
    var fontSize: CGFloat
    var palette: Palette
    var submit: () -> Void
    var cancel: () -> Void
    var moveSelection: ((Int) -> Void)? = nil
    var autofocus = true
    var beginEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InputField {
        let field = InputField()
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(placeholder)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: InputField, context: Context) {
        context.coordinator.input = self
        if field.stringValue != text { field.stringValue = text }
        let font = NSFont.systemFont(ofSize: fontSize)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: palette.text.nsColor, .font: font]
        )
        field.font = font
        field.textColor = palette.text.nsColor
        field.beginEditing = beginEditing
        let shouldFocus = autofocus && !field.autofocus
        field.autofocus = autofocus
        if shouldFocus { field.focusWhenReady() }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var input: WorkInput
        init(_ input: WorkInput) { self.input = input }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { input.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)): input.submit(); return true
            case #selector(NSResponder.cancelOperation(_:)): input.cancel(); return true
            case #selector(NSResponder.moveUp(_:)):
                guard !textView.hasMarkedText(), let move = input.moveSelection else { return false }
                move(-1); return true
            case #selector(NSResponder.moveDown(_:)):
                guard !textView.hasMarkedText(), let move = input.moveSelection else { return false }
                move(1); return true
            default: return false
            }
        }
    }

    final class InputField: NSTextField {
        var autofocus = false
        var beginEditing: () -> Void = {}

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                (currentEditor() as? NSTextView).map(Self.plain)
                beginEditing()
            }
            return accepted
        }

        /// Addresses, searches, and find queries are not prose. Checking one
        /// cost about 84 ms on the main thread each time the field gave up
        /// focus, and smart quotes and dashes rewrote what was typed. Every
        /// text field in the browser window is a WorkInput, so the window's
        /// shared field editor can stay this way.
        private static func plain(_ editor: NSTextView) {
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            // The switches above leave language detection on, which was most
            // of the cost.
            editor.enabledTextCheckingTypes = 0
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenReady()
        }

        func focusWhenReady() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.autofocus, let window = self.window, self.currentEditor() == nil else { return }
                window.makeFirstResponder(self)
                self.selectText(nil)
            }
        }
    }
}
