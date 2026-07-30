import SwiftUI

#if canImport(UIKit)
    import UIKit

    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
#elseif canImport(AppKit)
    import AppKit

    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
#endif

/// A Markdown editor that renders as you type.
///
/// Built on the platform text view rather than SwiftUI's `TextEditor` because that
/// one cannot be given attributes at all on iOS 18, and because the parts that
/// matter here are the parts SwiftUI does not expose: what happens to the selection
/// when the styling is reapplied, and what lands on the clipboard.
///
/// Two decisions carry the whole design.
///
/// **The buffer is never rewritten.** Styling only sets attributes, so the text is
/// always exactly what was typed. Copy yields Markdown, paste inserts what was
/// copied, undo undoes one edit rather than an edit and a reformat, and the caret
/// moves one character per keypress everywhere including through a `**`. An editor
/// that hid its markers would have to special-case the caret at every boundary and
/// would still put the wrong thing on the clipboard.
///
/// **The selection is preserved explicitly.** Setting attributes on the text
/// storage moves the selection on both platforms, so it is read before and restored
/// after. Getting this wrong is not cosmetic: the caret jumps to the end of the
/// document mid-sentence.
struct PlusMarkdownEditor: View {
    @Binding var text: String
    /// Shown when the document is empty, in place of the text.
    var placeholder: String = ""
    /// Lets the composer's formatting buttons act on the live selection.
    var handle: PlusMarkdownEditorHandle? = nil

    var body: some View {
        Representable(text: $text, placeholder: placeholder, handle: handle)
            .overlay(alignment: .topLeading) {
                if text.isEmpty, !placeholder.isEmpty {
                    Text(verbatim: placeholder)
                        .foregroundStyle(.tertiary)
                        // Lines up with the text container's inset rather than being
                        // eyeballed, so the first character does not jump when it
                        // replaces this.
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The composer's way to act on the text view's selection.
///
/// A formatting button has to know what is selected, and SwiftUI does not expose that
/// for a text view it does not own. Rather than mirror the selection into SwiftUI —
/// which would mean writing observed state on every caret move, for a value only these
/// buttons read — the composer hands this down and the editor attaches itself to it.
///
/// The edit itself is decided by ``PlusMarkdownEdit``, which is pure and tested. All
/// that happens here is handing it the current text and selection, and applying what
/// comes back through the text view's own editing API so undo records one step.
@MainActor
final class PlusMarkdownEditorHandle {
    fileprivate var attachment: ((@escaping (String, NSRange) -> PlusMarkdownEdit.Edit) -> Void)?

    /// Whether an editor is attached. False before the editor appears, which is when a
    /// button would otherwise look enabled and do nothing.
    var isReady: Bool { attachment != nil }

    func perform(_ edit: @escaping (String, NSRange) -> PlusMarkdownEdit.Edit) {
        attachment?(edit)
    }
}

// MARK: - Styling

/// Turns the styler's spans into the attributes a text view draws.
///
/// Separate from the styler so what a range *is* stays independent of how it looks.
/// Internal rather than private so what the writer actually sees can be asserted:
/// the styler's spans being right does not prove the right font reaches the screen.
enum MarkdownAttributes {
    /// The size body text is drawn at. Headings scale from it, so one change moves
    /// the whole document.
    static var bodySize: CGFloat {
        #if canImport(UIKit)
            UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
            NSFont.systemFontSize + 1
        #endif
    }

    /// What every character starts as, before the styler's spans are laid over it.
    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = bodySize * 0.45
        return [
            .font: PlatformFont.systemFont(ofSize: bodySize),
            .foregroundColor: PlatformColor.labelCompat,
            .paragraphStyle: paragraph,
        ]
    }

    static func attributed(_ text: String, accent: PlatformColor) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text)
        restyle(result, accent: accent)
        return result
    }

    /// Restyles storage in place, touching only attributes.
    ///
    /// The characters are never replaced, which is what makes this safe to run on a
    /// live text view: replacing them takes the undo stack, the selection, and any
    /// in-progress input-method composition down with it. Both platforms go through
    /// here so neither can drift from the other, and so the behaviour can be tested
    /// without a text view.
    static func restyle(_ storage: NSMutableAttributedString, accent: PlatformColor) {
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes(), range: whole)

        let full = text.startIndex..<text.endIndex
        for span in PlusMarkdownStyler.spans(in: text) {
            guard span.range.clamped(to: full) == span.range, !span.range.isEmpty else { continue }
            let range = NSRange(span.range, in: text)
            for (key, value) in attributes(for: span.kind, accent: accent) {
                storage.addAttribute(key, value: value, range: range)
            }
        }
    }

    static func attributes(
        for kind: PlusMarkdownStyler.Kind, accent: PlatformColor
    ) -> [NSAttributedString.Key: Any] {
        let size = bodySize
        let mono = PlatformFont.monospacedSystemFont(ofSize: size * 0.94, weight: .regular)

        switch kind {
        case .body:
            return [:]
        case .heading(let level):
            // Level 1 is noticeably larger; by level 4 the weight carries it. A
            // scale that kept growing would make an outline look like a poster.
            let scale: CGFloat = [1.62, 1.38, 1.2, 1.08, 1.02, 1.0][min(level, 6) - 1]
            return [.font: PlatformFont.boldSystemFont(ofSize: size * scale)]
        case .bold:
            return [.font: PlatformFont.boldSystemFont(ofSize: size)]
        case .italic:
            return [.font: italic(ofSize: size)]
        case .boldItalic:
            return [.font: boldItalic(ofSize: size)]
        case .strikethrough:
            return [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: PlatformColor.secondaryLabelCompat,
            ]
        case .inlineCode, .codeBlock, .tableRow:
            return [.font: mono, .foregroundColor: accent]
        case .quote:
            return [.font: italic(ofSize: size), .foregroundColor: PlatformColor.secondaryLabelCompat]
        case .linkText:
            return [.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .url:
            return [.font: mono, .foregroundColor: PlatformColor.secondaryLabelCompat]
        case .marker:
            // Faint, not hidden. Present enough to see the structure, quiet enough
            // to read past.
            return [.foregroundColor: PlatformColor.tertiaryLabelCompat]
        }
    }

    private static func italic(ofSize size: CGFloat) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size)
        #if canImport(UIKit)
            guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) else {
                return base
            }
            return UIFont(descriptor: descriptor, size: size)
        #else
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        #endif
    }

    private static func boldItalic(ofSize size: CGFloat) -> PlatformFont {
        let base = PlatformFont.boldSystemFont(ofSize: size)
        #if canImport(UIKit)
            guard
                let descriptor = base.fontDescriptor.withSymbolicTraits([.traitItalic, .traitBold])
            else { return base }
            return UIFont(descriptor: descriptor, size: size)
        #else
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        #endif
    }
}

extension PlatformColor {
    static var secondaryLabelCompat: PlatformColor {
        #if canImport(UIKit)
            .secondaryLabel
        #else
            .secondaryLabelColor
        #endif
    }

    static var tertiaryLabelCompat: PlatformColor {
        #if canImport(UIKit)
            .tertiaryLabel
        #else
            .tertiaryLabelColor
        #endif
    }

    static var labelCompat: PlatformColor {
        #if canImport(UIKit)
            .label
        #else
            .labelColor
        #endif
    }
}

// MARK: - iOS

#if canImport(UIKit)
    extension PlusMarkdownEditor {
        fileprivate struct Representable: UIViewRepresentable {
            @Binding var text: String
            let placeholder: String
            let handle: PlusMarkdownEditorHandle?
            @Environment(\.self) private var environment

            func makeUIView(context: Context) -> UITextView {
                let view = UITextView()
                view.backgroundColor = .clear
                view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
                view.textContainer.lineFragmentPadding = 0
                view.delegate = context.coordinator
                view.alwaysBounceVertical = true
                view.keyboardDismissMode = .interactive
                // Smart quotes and dashes rewrite what was typed, which in Markdown
                // can turn a quote into a character no parser expects and a `--`
                // into an en dash inside a code span.
                view.smartQuotesType = .no
                view.smartDashesType = .no
                view.autocorrectionType = .yes
                view.spellCheckingType = .yes
                context.coordinator.replace(text, in: view)
                // Weakly, so the handle outliving the view cannot keep it alive, and a
                // button pressed after the editor is gone does nothing rather than
                // acting on a detached view.
                handle?.attachment = { [weak view] makeEdit in
                    guard let view else { return }
                    context.coordinator.apply(makeEdit, to: view)
                }
                return view
            }

            func updateUIView(_ view: UITextView, context: Context) {
                context.coordinator.text = $text
                context.coordinator.accent = accentColor
                // Only when the text differs from what the view holds. Restyling on
                // every SwiftUI update would fight the keyboard.
                if view.text != text {
                    context.coordinator.replace(text, in: view)
                }
                view.tintColor = accentColor
            }

            func makeCoordinator() -> Coordinator {
                Coordinator(text: $text, accent: accentColor)
            }

            private var accentColor: UIColor {
                UIColor(PlusTheme.accent)
            }
        }

        fileprivate final class Coordinator: NSObject, UITextViewDelegate {
            var text: Binding<String>
            var accent: UIColor

            init(text: Binding<String>, accent: UIColor) {
                self.text = text
                self.accent = accent
            }

            /// Replaces the whole document, for text that came from outside the view.
            func replace(_ source: String, in view: UITextView) {
                view.attributedText = MarkdownAttributes.attributed(source, accent: accent)
                restyle(view)
            }

            /// Restyles what the view already holds, in place.
            ///
            /// Through the text storage rather than by assigning `attributedText`.
            /// Assigning it replaces every character, which on each keystroke:
            /// collapsed the selection to the end of the document, discarded the undo
            /// stack so undo could not step back through an edit, and ended any
            /// in-progress input-method composition — the last of which matters most
            /// for anyone writing in Korean, Japanese, or Chinese, where a syllable is
            /// assembled over several keypresses and this threw the assembly away.
            ///
            /// Nothing here changes a character, so the view does not consider it an
            /// edit at all.
            func restyle(_ view: UITextView) {
                // Never mid-composition. The marked text belongs to the keyboard until
                // it commits, and attributes applied over it are both discarded and
                // disruptive. The commit itself reports another change, which styles it.
                guard view.markedTextRange == nil, let storage = view.textStorage as NSTextStorage? else {
                    return
                }
                let selection = view.selectedRange
                storage.beginEditing()
                MarkdownAttributes.restyle(storage, accent: accent)
                storage.endEditing()
                // Attribute-only edits should leave the selection alone, but the text
                // system is not required to, and a caret that jumps mid-sentence is
                // the worst thing an editor can do. Cheap to be certain.
                if view.selectedRange != selection {
                    view.selectedRange = selection
                }
                // Typing attributes are separate from the storage, and left alone they
                // carry the last styled run into whatever is typed next: a caret after
                // a heading would keep typing at heading size.
                view.typingAttributes = MarkdownAttributes.baseAttributes()
            }

            func textViewDidChange(_ view: UITextView) {
                text.wrappedValue = view.text
                restyle(view)
            }

            /// Runs a formatting edit against the live selection.
            ///
            /// Through `replace(_:withText:)` rather than by assigning the text, so the
            /// text view records one undo step for one button press, reports the change
            /// to this delegate (which restyles and updates the binding), and leaves
            /// the rest of the document untouched.
            func apply(
                _ makeEdit: (String, NSRange) -> PlusMarkdownEdit.Edit, to view: UITextView
            ) {
                let edit = makeEdit(view.text, view.selectedRange)
                guard
                    let start = view.position(from: view.beginningOfDocument, offset: edit.range.location),
                    let end = view.position(from: start, offset: edit.range.length),
                    let range = view.textRange(from: start, to: end)
                else { return }
                view.replace(range, withText: edit.replacement)
                view.selectedRange = edit.selection
                // `replace` reports the change, but only for a non-empty replacement on
                // some paths; keeping the binding in step is cheap and unconditional.
                text.wrappedValue = view.text
            }
        }
    }
#endif

// MARK: - macOS

#if !canImport(UIKit) && canImport(AppKit)
    extension PlusMarkdownEditor {
        fileprivate struct Representable: NSViewRepresentable {
            @Binding var text: String
            let placeholder: String
            let handle: PlusMarkdownEditorHandle?

            func makeNSView(context: Context) -> NSScrollView {
                let scroll = NSTextView.scrollableTextView()
                guard let view = scroll.documentView as? NSTextView else { return scroll }
                scroll.drawsBackground = false
                view.drawsBackground = false
                view.delegate = context.coordinator
                view.isRichText = false
                view.allowsUndo = true
                view.textContainerInset = NSSize(width: 4, height: 8)
                // Same reasoning as iOS: substitutions rewrite Markdown into
                // characters no parser expects.
                view.isAutomaticQuoteSubstitutionEnabled = false
                view.isAutomaticDashSubstitutionEnabled = false
                view.isAutomaticTextReplacementEnabled = false
                view.isContinuousSpellCheckingEnabled = true
                context.coordinator.replace(text, in: view)
                handle?.attachment = { [weak view] makeEdit in
                    guard let view else { return }
                    context.coordinator.apply(makeEdit, to: view)
                }
                return scroll
            }

            func updateNSView(_ scroll: NSScrollView, context: Context) {
                guard let view = scroll.documentView as? NSTextView else { return }
                context.coordinator.text = $text
                if view.string != text {
                    context.coordinator.replace(text, in: view)
                }
            }

            func makeCoordinator() -> Coordinator {
                Coordinator(text: $text, accent: NSColor(PlusTheme.accent))
            }
        }

        fileprivate final class Coordinator: NSObject, NSTextViewDelegate {
            var text: Binding<String>
            var accent: NSColor

            init(text: Binding<String>, accent: NSColor) {
                self.text = text
                self.accent = accent
            }

            /// Replaces the whole document, for text that came from outside the view.
            func replace(_ source: String, in view: NSTextView) {
                guard let storage = view.textStorage else { return }
                storage.setAttributedString(MarkdownAttributes.attributed(source, accent: accent))
                restyle(view)
            }

            /// Restyles in place through the text storage, so the undo stack and the
            /// selection both survive. Replacing the string instead would collapse the
            /// selection and record an undo step for a change nobody made.
            func restyle(_ view: NSTextView) {
                // Same rule as iOS: the marked text belongs to the input method until
                // it commits, and the commit reports its own change.
                guard view.markedRange().length == 0, let storage = view.textStorage else { return }
                let selection = view.selectedRange()
                storage.beginEditing()
                MarkdownAttributes.restyle(storage, accent: accent)
                storage.endEditing()

                if view.selectedRange() != selection {
                    let limit = storage.length
                    view.setSelectedRange(
                        NSRange(
                            location: min(selection.location, limit),
                            length: min(selection.length, limit - min(selection.location, limit))))
                }
                view.typingAttributes = MarkdownAttributes.baseAttributes()
            }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                text.wrappedValue = view.string
                restyle(view)
            }

            /// See the iOS coordinator: routed through the text view's own editing API
            /// so one button press is one undo step.
            func apply(
                _ makeEdit: (String, NSRange) -> PlusMarkdownEdit.Edit, to view: NSTextView
            ) {
                let edit = makeEdit(view.string, view.selectedRange())
                // The documented order for a programmatic edit: ask, change the
                // storage, then report. `shouldChangeText` is what opens the undo
                // grouping, so one button press stays one undo step.
                guard view.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
                    return
                }
                view.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
                view.didChangeText()
                view.setSelectedRange(edit.selection)
                text.wrappedValue = view.string
            }
        }
    }
#endif
