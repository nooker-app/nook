#if os(macOS)
import AppKit
import SwiftUI

/// Handle search commands in the field editor, where Korean IME composition
/// and macOS key bindings are known. No application-wide keyboard monitor.
struct ArticleSearchField: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Bool
    let submit: () -> Bool
    let escape: () -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.placeholderString = String(localized: "Search by keyword or meaning", bundle: .module)
        field.setAccessibilityLabel(field.placeholderString)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ArticleSearchField
        init(_ parent: ArticleSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText(), NSEvent.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            switch NSStringFromSelector(selector) {
            case "moveDown:": return parent.move(1)
            case "moveUp:": return parent.move(-1)
            case "insertNewline:": return parent.submit()
            case "cancelOperation:": return parent.escape()
            default: return false
            }
        }
    }
}
#endif
