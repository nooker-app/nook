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

    var body: some View {
        Representable(text: $text, placeholder: placeholder)
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

    static func attributed(_ text: String, accent: PlatformColor) -> NSMutableAttributedString {
        let body = PlatformFont.systemFont(ofSize: bodySize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = bodySize * 0.45

        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: body,
                .foregroundColor: PlatformColor.labelCompat,
                .paragraphStyle: paragraph,
            ])

        let full = text.startIndex..<text.endIndex
        for span in PlusMarkdownStyler.spans(in: text) {
            guard span.range.clamped(to: full) == span.range, !span.range.isEmpty else { continue }
            let range = NSRange(span.range, in: text)
            for (key, value) in attributes(for: span.kind, accent: accent) {
                result.addAttribute(key, value: value, range: range)
            }
        }
        return result
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
                context.coordinator.apply(text, to: view)
                return view
            }

            func updateUIView(_ view: UITextView, context: Context) {
                context.coordinator.text = $text
                context.coordinator.accent = accentColor
                // Only when the text differs from what the view holds. Restyling on
                // every SwiftUI update would fight the keyboard.
                if view.text != text {
                    context.coordinator.apply(text, to: view)
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

            /// Replaces the styled text, keeping the selection where it was.
            ///
            /// Assigning to `attributedText` collapses the selection to the end, so
            /// it is captured first and put back. Without this the caret leaves the
            /// middle of a sentence on every keystroke.
            func apply(_ source: String, to view: UITextView) {
                let selection = view.selectedRange
                view.attributedText = MarkdownAttributes.attributed(source, accent: accent)
                // Clamped, because the text may be shorter than it was.
                let limit = (view.text as NSString).length
                view.selectedRange = NSRange(
                    location: min(selection.location, limit),
                    length: min(selection.length, limit - min(selection.location, limit)))
                // Typing attributes are separate from the storage, and left alone
                // they carry the last styled run into whatever is typed next: a
                // caret after a heading would keep typing at heading size.
                view.typingAttributes = [
                    .font: UIFont.systemFont(ofSize: MarkdownAttributes.bodySize),
                    .foregroundColor: UIColor.label,
                ]
            }

            func textViewDidChange(_ view: UITextView) {
                text.wrappedValue = view.text
                apply(view.text, to: view)
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
                context.coordinator.apply(text, to: view)
                return scroll
            }

            func updateNSView(_ scroll: NSScrollView, context: Context) {
                guard let view = scroll.documentView as? NSTextView else { return }
                context.coordinator.text = $text
                if view.string != text {
                    context.coordinator.apply(text, to: view)
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

            /// Restyles in place through the text storage, so the undo stack and the
            /// selection both survive. Replacing the string instead would collapse
            /// the selection and record an undo step for a change nobody made.
            func apply(_ source: String, to view: NSTextView) {
                guard let storage = view.textStorage else { return }
                let selection = view.selectedRange()
                let styled = MarkdownAttributes.attributed(source, accent: accent)

                storage.beginEditing()
                if storage.string == source {
                    let whole = NSRange(location: 0, length: storage.length)
                    storage.setAttributes(nil, range: whole)
                    styled.enumerateAttributes(in: whole) { attributes, range, _ in
                        storage.setAttributes(attributes, range: range)
                    }
                } else {
                    storage.setAttributedString(styled)
                }
                storage.endEditing()

                let limit = storage.length
                view.setSelectedRange(
                    NSRange(
                        location: min(selection.location, limit),
                        length: min(selection.length, limit - min(selection.location, limit))))
                view.typingAttributes = [
                    .font: NSFont.systemFont(ofSize: MarkdownAttributes.bodySize),
                    .foregroundColor: NSColor.labelColor,
                ]
            }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                text.wrappedValue = view.string
                apply(view.string, to: view)
            }
        }
    }
#endif
