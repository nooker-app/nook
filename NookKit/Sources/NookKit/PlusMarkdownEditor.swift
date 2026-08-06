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
    /// The label and the text view's exact live source. Passing the source avoids
    /// reopening from a SwiftUI binding that may still be one update behind TextKit.
    var onOpenFootnote: (String, String) -> Void = { _, _ in }
    var onOpenTableOfContents: () -> Void = {}
    var onRequestFootnote: () -> Void = {}
    var onRequestHelp: () -> Void = {}
    /// Space at the foot of the document to keep clear, for whatever the composer draws
    /// over the editor. The text view needs to be told: it decides the caret is visible
    /// from its own bounds and cannot see what is on top of it.
    var bottomInset: CGFloat = 0

    var body: some View {
        Representable(
            text: $text,
            placeholder: placeholder,
            handle: handle,
            onOpenFootnote: onOpenFootnote,
            onOpenTableOfContents: onOpenTableOfContents,
            onRequestFootnote: onRequestFootnote,
            onRequestHelp: onRequestHelp,
            bottomInset: bottomInset)
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
    fileprivate var transactionAttachment:
        ((@escaping (String, NSRange) -> PlusMarkdownEdit.Transaction) -> Void)?
    fileprivate var takeFocus: (() -> Void)?
    fileprivate var selectRange: ((NSRange) -> Void)?

    /// Whether an editor is attached. False before the editor appears, which is when a
    /// button would otherwise look enabled and do nothing.
    var isReady: Bool { attachment != nil }

    func perform(_ edit: @escaping (String, NSRange) -> PlusMarkdownEdit.Edit) {
        attachment?(edit)
    }

    func performTransaction(
        _ transaction: @escaping (String, NSRange) -> PlusMarkdownEdit.Transaction
    ) {
        transactionAttachment?(transaction)
    }

    /// Puts the caret in the body.
    ///
    /// Needed because `@FocusState` cannot move focus into a text view SwiftUI does not
    /// own: `.focused(_:equals:)` on a representable registers a value nothing ever
    /// sets or acts on, so Return at the end of the title did nothing at all.
    func focus() {
        takeFocus?()
    }

    func select(_ range: NSRange) {
        selectRange?(range)
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

    /// Attributes new text should receive at a UTF-16 insertion point.
    ///
    /// AppKit gives marked text (the syllable a Korean IME is still composing) the
    /// text view's `typingAttributes`. Asking the fully styled document for those
    /// attributes is insufficient at the end of an empty heading, because there is
    /// no character there yet. A temporary probe character lets the same Markdown
    /// rules answer what the next character would be without touching the editor's
    /// storage or its marked text.
    static func typingAttributes(
        for text: String, atUTF16Offset offset: Int, accent: PlatformColor
    ) -> [NSAttributedString.Key: Any] {
        let location = min(max(0, offset), text.utf16.count)
        let insertion = String.Index(utf16Offset: location, in: text)
        var probe = text
        probe.insert("x", at: insertion)
        return attributed(probe, accent: accent).attributes(at: location, effectiveRange: nil)
    }

    /// Restyles storage in place, touching only attributes.
    ///
    /// The characters are never replaced, which is what makes this safe to run on a
    /// live text view: replacing them takes the undo stack, the selection, and any
    /// in-progress input-method composition down with it. Both platforms go through
    /// here so neither can drift from the other, and so the behaviour can be tested
    /// without a text view.
    /// Fonts are gathered as intents and written once, at the end, because nesting has to
    /// compose rather than replace. Everything else is set as it arrives.
    static func restyle(_ storage: NSMutableAttributedString, accent: PlatformColor) {
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes(), range: whole)

        let full = text.startIndex..<text.endIndex
        var intents = [FontIntent](repeating: .body, count: storage.length)
        for span in PlusMarkdownStyler.spans(in: text) {
            guard span.range.clamped(to: full) == span.range, !span.range.isEmpty else { continue }
            let range = NSRange(span.range, in: text)
            for (key, value) in attributes(for: span.kind, accent: accent) {
                storage.addAttribute(key, value: value, range: range)
            }
            guard let intent = fontIntent(for: span.kind) else { continue }
            for offset in range.location..<NSMaxRange(range) {
                intents[offset].merge(intent)
            }
        }

        // One write per run of equal intent. Plain text is skipped: the base attributes
        // above already gave it the body font, and every write here is a range of TextKit
        // layout invalidated.
        var start = 0
        while start < intents.count {
            var end = start + 1
            while end < intents.count, intents[end] == intents[start] { end += 1 }
            if intents[start] != .body {
                storage.addAttribute(
                    .font, value: font(for: intents[start]),
                    range: NSRange(location: start, length: end - start))
            }
            start = end
        }
    }

    /// What a span wants of the font, rather than which font that is.
    ///
    /// Spans overlap — `***this***` arrives as bold-italic *and* bold *and* italic over the
    /// same characters, a heading contains its own emphasis, a table row contains
    /// everything — and the previous pass set `.font` per span, so the last one to arrive
    /// won. Bold italic came out as italic alone, a bold word inside a heading shrank to
    /// body size, and code inside a heading lost the heading's size.
    ///
    /// Composition cannot depend on the order the spans arrive in, because that order is
    /// not consistent: a heading is reported before the emphasis inside it, while the bold
    /// inside a link is reported before the link. So both operations here are commutative —
    /// the traits union, and the scale multiplies.
    struct FontIntent: Equatable {
        var bold = false
        var italic = false
        var monospace = false
        /// Relative to body size, and multiplied rather than assigned, so that code inside
        /// a heading is monospaced at the heading's size.
        var scale: CGFloat = 1

        static let body = FontIntent()

        mutating func merge(_ other: FontIntent) {
            bold = bold || other.bold
            italic = italic || other.italic
            monospace = monospace || other.monospace
            scale *= other.scale
        }
    }

    /// The font an intent resolves to.
    ///
    /// Always built from `bodySize` and the intent, never from whatever font is already in
    /// the storage. That is what keeps restyling idempotent: a second pass over settled
    /// text computes the same fonts and therefore writes nothing, which is what keeps
    /// TextKit from re-laying out the document on every keystroke.
    static func font(for intent: FontIntent) -> PlatformFont {
        let size = bodySize * intent.scale
        if intent.monospace {
            // No italic: the monospaced system font has no italic face to ask for, and a
            // synthesised slant on code is worse than none.
            return PlatformFont.monospacedSystemFont(
                ofSize: size, weight: intent.bold ? .bold : .regular)
        }
        switch (intent.bold, intent.italic) {
        case (true, true): return boldItalic(ofSize: size)
        case (true, false): return PlatformFont.boldSystemFont(ofSize: size)
        case (false, true): return italic(ofSize: size)
        case (false, false): return PlatformFont.systemFont(ofSize: size)
        }
    }

    /// What each kind asks of the font. Nil for the kinds that have no opinion about it.
    static func fontIntent(for kind: PlusMarkdownStyler.Kind) -> FontIntent? {
        switch kind {
        case .heading(let level):
            // Level 1 is noticeably larger; by level 4 the weight carries it. A scale that
            // kept growing would make an outline look like a poster.
            let scale: CGFloat = [1.62, 1.38, 1.2, 1.08, 1.02, 1.0][min(level, 6) - 1]
            return FontIntent(bold: true, scale: scale)
        case .bold, .tableOfContents:
            return FontIntent(bold: true)
        case .italic, .quote:
            return FontIntent(italic: true)
        case .boldItalic:
            return FontIntent(bold: true, italic: true)
        case .inlineCode, .codeBlock, .tableRow, .url, .footnoteDefinition:
            return FontIntent(monospace: true, scale: 0.94)
        case .footnoteReference:
            return FontIntent(bold: true, scale: 0.82)
        case .body, .strikethrough, .linkText, .softBreak, .hardBreak, .marker:
            return nil
        }
    }

    /// Applies only the rendered attributes that actually changed.
    ///
    /// AppKit invalidates text layout for every range whose font or paragraph style
    /// is touched. Resetting the whole document after each keystroke therefore makes
    /// a bottom-pinned scroll view recalculate its full height while `NSTextView` is
    /// also scrolling the caret into view. A list's separating space made this
    /// especially visible: two marker characters changed colour, but every paragraph
    /// was invalidated.
    ///
    /// The Markdown pass remains document-wide so constructs such as fenced code stay
    /// correct. Only its attribute delta reaches the live text storage. Kept separate
    /// from ``restyle(_:accent:)`` because UIKit already has stable scrolling and does
    /// not need its editing path changed.
    @discardableResult
    static func restyleChangedAttributes(
        _ storage: NSMutableAttributedString, accent: PlatformColor
    ) -> [NSRange] {
        guard storage.length > 0 else { return [] }

        let expected = attributed(storage.string, accent: accent)
        let whole = NSRange(location: 0, length: storage.length)
        var edits: [(
            range: NSRange,
            attributes: [NSAttributedString.Key: Any],
            keys: [NSAttributedString.Key]
        )] = []

        expected.enumerateAttributes(in: whole) { expectedAttributes, expectedRange, _ in
            storage.enumerateAttributes(in: expectedRange) { currentAttributes, currentRange, _ in
                let keys = changedManagedKeys(currentAttributes, to: expectedAttributes)
                guard !keys.isEmpty else { return }
                edits.append((currentRange, expectedAttributes, keys))
            }
        }

        for edit in edits {
            for key in edit.keys {
                if let value = edit.attributes[key] {
                    storage.addAttribute(key, value: value, range: edit.range)
                } else {
                    storage.removeAttribute(key, range: edit.range)
                }
            }
        }
        return merged(edits.map(\.range))
    }

    private static let managedKeys: [NSAttributedString.Key] = [
        .font,
        .foregroundColor,
        .paragraphStyle,
        .strikethroughStyle,
        .underlineStyle,
        .link,
    ]

    private static func changedManagedKeys(
        _ lhs: [NSAttributedString.Key: Any],
        to rhs: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key] {
        managedKeys.filter { !attribute(lhs[$0], equals: rhs[$0]) }
    }

    private static func attribute(_ lhs: Any?, equals rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as NSObject, rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            guard let last = result.last, NSMaxRange(last) >= range.location else {
                result.append(range)
                continue
            }
            result[result.count - 1] = NSUnionRange(last, range)
        }
        return result
    }

    /// Everything a kind draws *except* its font, which is composed rather than set — see
    /// ``fontIntent(for:)``.
    static func attributes(
        for kind: PlusMarkdownStyler.Kind, accent: PlatformColor
    ) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .body, .heading, .bold, .italic, .boldItalic:
            return [:]
        case .strikethrough:
            return [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: PlatformColor.secondaryLabelCompat,
            ]
        case .inlineCode, .codeBlock, .tableRow:
            return [.foregroundColor: accent]
        case .quote:
            return [.foregroundColor: PlatformColor.secondaryLabelCompat]
        case .linkText:
            return [.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .url:
            return [.foregroundColor: PlatformColor.secondaryLabelCompat]
        case .tableOfContents:
            return [
                .foregroundColor: accent,
                .link: URL(string: "nook-toc://outline")!,
            ]
        case .footnoteReference(let label):
            var components = URLComponents()
            components.scheme = "nook-footnote"
            components.host = "reference"
            components.path = "/\(label)"
            return [
                .foregroundColor: accent,
                .link: components.url!,
            ]
        case .footnoteDefinition:
            return [.foregroundColor: accent]
        case .softBreak, .hardBreak:
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 0
            return [.paragraphStyle: paragraph]
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
            // Through the descriptor rather than `NSFontManager`, which is a main-thread
            // AppKit class this is in no position to promise it is on. Checked to give the
            // same answer: both routes return .SFNS-RegularItalic at the requested size.
            return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size)
                ?? base
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
            // Same as `italic`. Both traits are named rather than relying on the base
            // carrying the bold, which is what `NSFontManager` did here — it kept it, and
            // both routes end at .SFNS-BoldItalic, but only one of them says so.
            return NSFont(
                descriptor: base.fontDescriptor.withSymbolicTraits([.italic, .bold]), size: size)
                ?? base
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

// MARK: - Text arriving from SwiftUI

/// What to do with a text value SwiftUI hands down to the editor.
///
/// While the editor is on screen the text view *is* the writer's buffer and the
/// binding is a mirror of it. Both platforms used to compare the two and replace the
/// whole document whenever they differed, which is right for text that genuinely came
/// from somewhere else and wrong for the case that happens constantly: SwiftUI
/// re-running an update — a background sync changing something the composer reads —
/// carrying the value the editor itself published a moment ago, while a keystroke has
/// already moved the buffer past it. Replacing there resets the selection, the scroll
/// offset and the undo stack, which is the caret landing somewhere unintended that
/// gets reported as "focus jumps while syncing".
///
/// A value rather than a condition inside two `update…View` methods, because the rule
/// depends on the order of two update paths and that is exactly what cannot be
/// reproduced by hand. Both platforms decide through here so neither can drift.
///
/// One case is deliberately lossy. A genuinely new value that arrives while an input
/// method is composing is dropped, not queued: the commit publishes the buffer, so the
/// binding stops carrying it. Queueing it was tried and is what this comment is for —
/// deciding when a queued value is still wanted takes state that cannot be derived
/// (this editor's own intermediate publishes look exactly like the model changing its
/// mind), and getting it wrong reverts the syllable somebody just typed. What is lost
/// instead is narrow: the only writes from outside are the initial load, which happens
/// before there is anything to compose, and the reset to empty as the composer closes.
enum EditorTextArrival: Equatable {
    /// The buffer already holds what SwiftUI is offering.
    case upToDate
    /// SwiftUI is repeating something this editor said; the buffer is ahead of it.
    case echo
    /// An input method owns the buffer until it commits its marked text.
    case composing
    /// Text from somewhere other than this editor. Apply it.
    case external

    var appliesText: Bool { self == .external }

    /// - Parameters:
    ///   - incoming: what SwiftUI is offering.
    ///   - buffer: what the text view currently holds.
    ///   - published: values this editor recently wrote into the binding.
    ///   - isComposing: whether an input method has marked text in the buffer.
    static func decide(
        incoming: String,
        buffer: String,
        published: some Collection<String>,
        isComposing: Bool
    ) -> EditorTextArrival {
        if incoming == buffer { return .upToDate }
        // The echo check comes first, composition or not: a value this editor published
        // is not news whether or not an input method is busy. Deciding `.composing` first
        // instead meant a sync tick arriving during a Korean composition was treated as
        // external.
        //
        // Against several recent values rather than only the newest, because SwiftUI can
        // run an update from a body it evaluated more than one keystroke ago — which is
        // the whole reason this type exists.
        if published.contains(incoming) { return .echo }
        if isComposing { return .composing }
        return .external
    }
}

// MARK: - iOS

#if canImport(UIKit)
    /// The formatting bar above the keyboard.
    ///
    /// The text view's own `inputAccessoryView`, in UIKit, rather than SwiftUI's
    /// `.toolbar(placement: .keyboard)`.
    ///
    /// That placement is rendered for whichever *SwiftUI* view holds the focus, and the
    /// body is a `UITextView`. `.focused(_:equals:)` on a representable registers a
    /// value that nothing sets, because SwiftUI is never told the text view took the
    /// keyboard — so the bar appeared for the instant the title gave up focus and then
    /// never came back. An accessory view belongs to the responder itself, so it is
    /// shown exactly when this text view has the keyboard and at no other time.
    ///
    /// `UIInputView` rather than a plain view: it draws the keyboard's own background,
    /// so the bar looks attached to the keyboard instead of floating above it.
    final class PlusMarkdownAccessoryBar: UIInputView {
        /// One button: what it inserts, and what to call it.
        struct Item {
            let symbol: String
            let label: String
            let edit: (String, NSRange) -> PlusMarkdownEdit.Edit
            /// Ends the group it closes, drawn as a hairline after the button.
            var endsGroup = false
        }

        private let perform: (@escaping (String, NSRange) -> PlusMarkdownEdit.Edit) -> Void
        private let dismiss: () -> Void
        private let requestFootnote: () -> Void
        private let requestHelp: () -> Void

        init(
            accent: UIColor,
            perform: @escaping (@escaping (String, NSRange) -> PlusMarkdownEdit.Edit) -> Void,
            requestFootnote: @escaping () -> Void,
            requestHelp: @escaping () -> Void,
            dismiss: @escaping () -> Void
        ) {
            self.perform = perform
            self.requestFootnote = requestFootnote
            self.requestHelp = requestHelp
            self.dismiss = dismiss
            super.init(
                frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44),
                inputViewStyle: .keyboard)
            // An accessory view is sized by its frame, not by what is inside it, and
            // the keyboard resizes it by width alone. Without this it keeps whatever
            // width it was born with, which is wrong on rotation and on every device
            // but the one it happened to match.
            autoresizingMask = .flexibleWidth
            build(accent: accent)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        /// The markers that are two taps deep on a phone keyboard, in the order they
        /// get reached for: emphasis, then links, then structure.
        static var items: [Item] {
            [
                Item(
                    symbol: "bold", label: String(localized: "Bold", bundle: .module),
                    edit: { PlusMarkdownEdit.wrap($0, selection: $1, with: "**") }),
                Item(
                    symbol: "italic", label: String(localized: "Italic", bundle: .module),
                    edit: { PlusMarkdownEdit.wrap($0, selection: $1, with: "*") }),
                Item(
                    symbol: "link", label: String(localized: "Link", bundle: .module),
                    edit: { PlusMarkdownEdit.link($0, selection: $1) }, endsGroup: true),
                Item(
                    symbol: "number", label: String(localized: "Heading", bundle: .module),
                    edit: { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "## ") }),
                Item(
                    symbol: "list.bullet", label: String(localized: "List", bundle: .module),
                    edit: { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "- ") }),
                Item(
                    symbol: "text.quote", label: String(localized: "Quote", bundle: .module),
                    edit: { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "> ") }),
                Item(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    label: String(localized: "Code", bundle: .module),
                    edit: { PlusMarkdownEdit.codeBlock($0, selection: $1) }),
                Item(
                    symbol: "return.left",
                    label: String(localized: "Line break", bundle: .module),
                    edit: { PlusMarkdownEdit.breakLine($0, selection: $1, kind: .line) }),
                Item(
                    symbol: "list.bullet.indent",
                    label: String(localized: "Table of contents", bundle: .module),
                    edit: { PlusMarkdownEdit.tableOfContents($0, selection: $1) }),
            ]
        }

        private func build(accent: UIColor) {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 2

            for item in Self.items {
                row.addArrangedSubview(button(for: item, accent: accent))
                if item.endsGroup {
                    row.addArrangedSubview(separator())
                }
            }
            row.addArrangedSubview(actionButton(
                symbol: "text.badge.plus",
                label: String(localized: "Footnote", bundle: .module),
                accent: accent,
                action: requestFootnote))
            row.addArrangedSubview(actionButton(
                symbol: "questionmark.circle",
                label: String(localized: "Markdown help", bundle: .module),
                accent: accent,
                action: requestHelp))

            // Scrollable rather than squeezed: seven fixed buttons across the narrowest
            // phone leaves each too small to hit reliably, and the ones that fall off
            // the edge are the ones reached for least.
            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.alwaysBounceHorizontal = false
            scroll.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            ])

            // Pinned outside the scroll view, so the one button that is not about
            // formatting is always in the same place.
            let hide = UIButton(type: .system)
            hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
            hide.tintColor = accent
            hide.accessibilityLabel = String(localized: "Hide the keyboard", bundle: .module)
            hide.addAction(UIAction { [weak self] _ in self?.dismiss() }, for: .touchUpInside)

            let edge = separator()
            // Laid out with explicit constraints rather than an outer stack view. A
            // scroll view has no intrinsic width, so a stack would have had nothing to
            // size it from and could have given it none at all; here it is simply
            // whatever is left over.
            for child in [scroll, edge, hide] {
                child.translatesAutoresizingMaskIntoConstraints = false
                addSubview(child)
            }
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

                edge.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
                edge.topAnchor.constraint(equalTo: topAnchor),
                edge.bottomAnchor.constraint(equalTo: bottomAnchor),

                hide.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
                hide.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
                hide.topAnchor.constraint(equalTo: topAnchor),
                hide.bottomAnchor.constraint(equalTo: bottomAnchor),
                hide.widthAnchor.constraint(equalToConstant: 44),
            ])
        }

        private func button(for item: Item, accent: UIColor) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: item.symbol), for: .normal)
            button.tintColor = accent
            button.accessibilityLabel = item.label
            // 44 across is the smallest a target should be, and the bar's own height
            // gives the other axis.
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let edit = item.edit
            button.addAction(
                UIAction { [weak self] _ in self?.perform(edit) },
                for: .touchUpInside)
            return button
        }

        private func actionButton(
            symbol: String, label: String, accent: UIColor, action: @escaping () -> Void
        ) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.tintColor = accent
            button.accessibilityLabel = label
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return button
        }

        private func separator() -> UIView {
            let line = UIView()
            line.backgroundColor = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            let holder = UIView()
            holder.addSubview(line)
            NSLayoutConstraint.activate([
                line.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                line.heightAnchor.constraint(equalToConstant: 22),
                holder.widthAnchor.constraint(equalToConstant: 9),
            ])
            return holder
        }
    }

    extension PlusMarkdownEditor {
        fileprivate final class TextView: UITextView {
            var onHardBreak: (() -> Void)?

            override var keyCommands: [UIKeyCommand]? {
                var commands = super.keyCommands ?? []
                commands.append(
                    UIKeyCommand(
                        input: "\r",
                        modifierFlags: .shift,
                        action: #selector(insertNookHardBreak)))
                return commands
            }

            @objc private func insertNookHardBreak() {
                onHardBreak?()
            }
        }

        fileprivate struct Representable: UIViewRepresentable {
            @Binding var text: String
            let placeholder: String
            let handle: PlusMarkdownEditorHandle?
            let onOpenFootnote: (String, String) -> Void
            let onOpenTableOfContents: () -> Void
            let onRequestFootnote: () -> Void
            let onRequestHelp: () -> Void
            /// See PlusMarkdownEditor.bottomInset.
            let bottomInset: CGFloat

            /// The editor's own padding, before anything the composer reserves.
            static let baseTextInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)

            func makeUIView(context: Context) -> UITextView {
                let view = TextView()
                view.backgroundColor = .clear
                view.textContainerInset = Self.baseTextInset
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

                // The bar belongs to this responder, so it appears exactly when this
                // text view has the keyboard. Held weakly in both directions: the bar
                // must not keep the view alive, and the view owns the bar.
                view.inputAccessoryView = PlusMarkdownAccessoryBar(
                    accent: accentColor,
                    perform: { [weak view] edit in
                        guard let view else { return }
                        context.coordinator.apply(edit, to: view)
                    },
                    requestFootnote: onRequestFootnote,
                    requestHelp: onRequestHelp,
                    dismiss: { [weak view] in view?.resignFirstResponder() }
                )
                view.onHardBreak = { [weak view] in
                    guard let view else { return }
                    context.coordinator.apply(
                        { PlusMarkdownEdit.breakLine($0, selection: $1, kind: .line) },
                        to: view)
                }

                // Weakly, so the handle outliving the view cannot keep it alive, and a
                // button pressed after the editor is gone does nothing rather than
                // acting on a detached view.
                handle?.attachment = { [weak view] makeEdit in
                    guard let view else { return }
                    context.coordinator.apply(makeEdit, to: view)
                }
                handle?.transactionAttachment = { [weak view] makeTransaction in
                    guard let view else { return }
                    context.coordinator.apply(makeTransaction, to: view)
                }
                handle?.takeFocus = { [weak view] in view?.becomeFirstResponder() }
                handle?.selectRange = { [weak view] range in
                    guard let view else { return }
                    view.selectedRange = range
                    view.scrollRangeToVisible(range)
                    view.becomeFirstResponder()
                }
                return view
            }

            func updateUIView(_ view: UITextView, context: Context) {
                context.coordinator.text = $text
                context.coordinator.accent = accentColor
                context.coordinator.onOpenFootnote = onOpenFootnote
                context.coordinator.onOpenTableOfContents = onOpenTableOfContents
                // Only for text that genuinely came from elsewhere. A value equal to
                // what the view holds needs nothing; an echo of what this editor
                // published, or anything at all mid-composition, must not touch the
                // buffer. See EditorTextArrival.
                let arrival = EditorTextArrival.decide(
                    incoming: text,
                    buffer: view.text,
                    published: context.coordinator.published,
                    isComposing: view.markedTextRange != nil)
                switch arrival {
                case .external:
                    context.coordinator.replace(text, in: view)
                case .upToDate, .echo, .composing:
                    // Nothing. The buffer is either already right or is the input
                    // method's until it commits — see EditorTextArrival for what that
                    // deliberately gives up.
                    break
                }
                view.tintColor = accentColor
                // Set through the container rather than the frame: the text view keeps its
                // size, so nothing above it moves, and its own caret-revealing knows to
                // stay clear of the bottom.
                let reserved = Self.baseTextInset.bottom + bottomInset
                if view.textContainerInset.bottom != reserved {
                    view.textContainerInset.bottom = reserved
                    view.verticalScrollIndicatorInsets.bottom = bottomInset
                }
            }

            func makeCoordinator() -> Coordinator {
                Coordinator(
                    text: $text,
                    accent: accentColor,
                    onOpenFootnote: onOpenFootnote,
                    onOpenTableOfContents: onOpenTableOfContents)
            }

            private var accentColor: UIColor {
                UIColor(PlusTheme.accent)
            }
        }

        @MainActor
        fileprivate final class Coordinator: NSObject, UITextViewDelegate {
            var text: Binding<String>
            var accent: UIColor
            var onOpenFootnote: (String, String) -> Void
            var onOpenTableOfContents: () -> Void
            private var applyingProgrammaticEdit = false
            private var revision = 0
            private var titleTask: Task<Void, Never>?
            /// Values the buffer and the binding have recently agreed on — what this
            /// editor published, and what it accepted from outside. It is what lets the
            /// next SwiftUI update tell its own echo from a value someone else set.
            ///
            /// A few of them, newest last, because an update can run from a body SwiftUI
            /// evaluated several keystrokes ago. Bounded because it is a guard against
            /// staleness, not a history.
            private(set) var published: [String] = []
            private static let publishedMemory = 8

            init(
                text: Binding<String>,
                accent: UIColor,
                onOpenFootnote: @escaping (String, String) -> Void,
                onOpenTableOfContents: @escaping () -> Void
            ) {
                self.text = text
                self.accent = accent
                self.onOpenFootnote = onOpenFootnote
                self.onOpenTableOfContents = onOpenTableOfContents
            }

            /// Replaces the whole document, for text that came from outside the view.
            ///
            /// Assigning `attributedText` sends the selection to the end of the document
            /// and the scroll to the top. That is harmless when the editor is being
            /// created and disruptive on a live one, so where the writer was is put back
            /// afterwards — clamped, because the new text may be shorter than the old.
            func replace(_ source: String, in view: UITextView) {
                let selection = view.selectedRange
                let offset = view.contentOffset
                view.attributedText = MarkdownAttributes.attributed(source, accent: accent)
                record(source)
                // A different document. Anything still in flight belongs to the old one:
                // the URL-title resolution checks this before editing, and a stale value
                // here would let it write into text it never read.
                revision += 1
                titleTask?.cancel()
                titleTask = nil
                let limit = (view.text as NSString).length
                let location = min(selection.location, limit)
                view.selectedRange = NSRange(
                    location: location, length: min(selection.length, limit - location))
                // Laid out first so the content size the offset is clamped against is
                // the new document's, not the previous one's.
                view.layoutIfNeeded()
                // Against the scroll view's real range, insets included: while the
                // keyboard is up the valid bottom is past `contentSize`, and clamping to
                // `contentSize` alone would pull the writer up from where the keyboard
                // put them.
                let inset = view.adjustedContentInset
                let minY = -inset.top
                let maxY = max(minY, view.contentSize.height - view.bounds.height + inset.bottom)
                view.setContentOffset(
                    CGPoint(x: offset.x, y: min(max(offset.y, minY), maxY)), animated: false)
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
                MarkdownAttributes.restyleChangedAttributes(storage, accent: accent)
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
                guard !applyingProgrammaticEdit else { return }
                revision += 1
                publish(view.text)
                restyle(view)
            }

            /// Mirrors the buffer into the binding, remembering what was sent.
            ///
            /// The record is what lets the next SwiftUI update tell this editor's own
            /// value coming back from a value someone else set.
            private func publish(_ value: String) {
                record(value)
                text.wrappedValue = value
            }

            /// Notes a value the buffer and the binding now agree on.
            private func record(_ value: String) {
                published.append(value)
                if published.count > Self.publishedMemory { published.removeFirst() }
            }

            func textView(
                _ textView: UITextView,
                shouldChangeTextIn range: NSRange,
                replacementText replacement: String
            ) -> Bool {
                guard !applyingProgrammaticEdit, textView.markedTextRange == nil else { return true }
                if replacement == "\n" {
                    apply(
                        { source, _ in
                            PlusMarkdownEdit.breakLine(source, selection: range, kind: .paragraph)
                        },
                        to: textView)
                    return false
                }
                if let url = pastedURL(replacement),
                   !isMarkdownDestination(in: textView.text, selection: range)
                {
                    paste(url, selection: range, into: textView)
                    return false
                }
                return true
            }

            func textView(
                _ textView: UITextView,
                shouldInteractWith URL: URL,
                in characterRange: NSRange,
                interaction: UITextItemInteraction
            ) -> Bool {
                if URL.scheme == "nook-toc" {
                    onOpenTableOfContents()
                    return false
                }
                guard URL.scheme == "nook-footnote",
                    URL.host == "reference",
                    let label = URL.pathComponents.dropFirst().first
                else { return true }
                onOpenFootnote(label, textView.text)
                return false
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
                apply(edit, to: view)
            }

            private func apply(_ edit: PlusMarkdownEdit.Edit, to view: UITextView) {
                guard
                    let start = view.position(from: view.beginningOfDocument, offset: edit.range.location),
                    let end = view.position(from: start, offset: edit.range.length),
                    let range = view.textRange(from: start, to: end)
                else { return }
                applyingProgrammaticEdit = true
                view.replace(range, withText: edit.replacement)
                view.selectedRange = edit.selection
                applyingProgrammaticEdit = false
                // `replace` reports the change, but only for a non-empty replacement on
                // some paths; keeping the binding in step is cheap and unconditional.
                revision += 1
                publish(view.text)
                restyle(view)
            }

            func apply(
                _ makeTransaction: (String, NSRange) -> PlusMarkdownEdit.Transaction,
                to view: UITextView
            ) {
                let transaction = makeTransaction(view.text, view.selectedRange)
                let ordered = transaction.replacements.sorted {
                    if $0.range.location == $1.range.location {
                        return $0.range.length > $1.range.length
                    }
                    return $0.range.location > $1.range.location
                }
                let contentOffset = view.contentOffset
                applyingProgrammaticEdit = true
                view.undoManager?.beginUndoGrouping()
                for replacement in ordered {
                    guard
                        let start = view.position(
                            from: view.beginningOfDocument, offset: replacement.range.location),
                        let end = view.position(from: start, offset: replacement.range.length),
                        let range = view.textRange(from: start, to: end)
                    else { continue }
                    view.replace(range, withText: replacement.text)
                }
                view.undoManager?.endUndoGrouping()
                view.selectedRange = transaction.selection
                applyingProgrammaticEdit = false
                revision += 1
                publish(view.text)
                restyle(view)
                view.setContentOffset(contentOffset, animated: false)
            }

            private func paste(_ url: URL, selection: NSRange, into view: UITextView) {
                let paste = PlusMarkdownEdit.pasteURL(url, into: view.text, selection: selection)
                let shouldResolve = selection.length == 0
                apply(paste.edit, to: view)
                guard shouldResolve else { return }
                let expectedRevision = revision
                let expectedLabel = (view.text as NSString).substring(with: paste.labelRange)
                titleTask?.cancel()
                titleTask = Task { [weak self, weak view] in
                    guard let title = await PlusLinkTitleResolver.shared.title(for: url),
                        !title.isEmpty,
                        let self,
                        let view,
                        self.revision == expectedRevision,
                        NSMaxRange(paste.labelRange) <= (view.text as NSString).length,
                        (view.text as NSString).substring(with: paste.labelRange) == expectedLabel
                    else { return }
                    var edit = PlusMarkdownEdit.linkTitle(title, labelRange: paste.labelRange)
                    let selection = view.selectedRange
                    let delta = (edit.replacement as NSString).length - edit.range.length
                    edit.selection = selection.location >= edit.range.upperBound
                        ? NSRange(location: selection.location + delta, length: selection.length)
                        : selection
                    self.apply(edit, to: view)
                }
            }

            private func pastedURL(_ replacement: String) -> URL? {
                guard replacement == replacement.trimmingCharacters(in: .whitespacesAndNewlines),
                    !replacement.contains(where: \.isWhitespace),
                    let url = URL(string: replacement),
                    ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                    url.host != nil
                else { return nil }
                return url
            }

            private func isMarkdownDestination(in text: String, selection: NSRange) -> Bool {
                let ns = text as NSString
                let before = ns.substring(to: min(selection.location, ns.length))
                let beforeNS = before as NSString
                let open = beforeNS.range(of: "](", options: .backwards)
                guard open.location != NSNotFound else { return false }
                let suffix = beforeNS.substring(from: open.location + open.length)
                return !suffix.contains(")")
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
            let onOpenFootnote: (String, String) -> Void
            let onOpenTableOfContents: () -> Void
            let onRequestFootnote: () -> Void
            let onRequestHelp: () -> Void
            /// See PlusMarkdownEditor.bottomInset.
            let bottomInset: CGFloat

            func makeNSView(context: Context) -> NSScrollView {
                let scroll = NSTextView.scrollableTextView()
                guard let view = scroll.documentView as? NSTextView else { return scroll }
                scroll.drawsBackground = false
                // The composer sets the bottom inset itself; AppKit's automatic
                // adjustment would overwrite it.
                scroll.automaticallyAdjustsContentInsets = false
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
                // The rest of the automatic rewriting, which these three lines had left
                // following the system settings — and on a Mac with the defaults, that
                // means on.
                //
                // Every one of them acts at a word boundary, which is to say on a space,
                // and a backspace immediately after one is how macOS reverts it. That is
                // exactly the pair of keys still reported as moving the scroll on the last
                // line, and it is where the caret sits at the edge of the viewport with
                // nothing below it to absorb a change.
                //
                // Link detection is the one that is provably wrong here rather than merely
                // suspected: it adds `.link`, which is one of the attributes the Markdown
                // pass manages, so the next restyle removes it as an attribute that should
                // not be there and detection adds it again — two attribute writes and two
                // layout invalidations per boundary, for a link the writer expressed in
                // Markdown anyway.
                //
                // Correction and completion are refused on the editor's own terms: the
                // buffer is never rewritten, the text is always exactly what was typed.
                // Misspellings are still underlined; nothing is changed underneath.
                view.isAutomaticSpellingCorrectionEnabled = false
                view.isAutomaticTextCompletionEnabled = false
                view.isAutomaticLinkDetectionEnabled = false
                view.isAutomaticDataDetectionEnabled = false
                view.isContinuousSpellCheckingEnabled = true
                context.coordinator.replace(text, in: view)
                // Lay the whole document out once, here, where a few milliseconds are
                // invisible. Measured: the first full layout of a 2,000-word post takes
                // about 50ms and an 8,000-word one about 135ms, while every layout after it
                // costs under a millisecond because TextKit keeps what it has already laid
                // out. Left to happen on the first keystroke instead, that one-off would be
                // a hitch on the writer's first character.
                context.coordinator.finishLayout(of: view)
                handle?.attachment = { [weak view] makeEdit in
                    guard let view else { return }
                    context.coordinator.apply(makeEdit, to: view)
                }
                handle?.transactionAttachment = { [weak view] makeTransaction in
                    guard let view else { return }
                    context.coordinator.apply(makeTransaction, to: view)
                }
                handle?.takeFocus = { [weak view] in
                    guard let view else { return }
                    view.window?.makeFirstResponder(view)
                }
                handle?.selectRange = { [weak view] range in
                    guard let view else { return }
                    view.setSelectedRange(range)
                    view.scrollRangeToVisible(range)
                    view.window?.makeFirstResponder(view)
                }
                return scroll
            }

            func updateNSView(_ scroll: NSScrollView, context: Context) {
                guard let view = scroll.documentView as? NSTextView else { return }
                context.coordinator.text = $text
                context.coordinator.onOpenFootnote = onOpenFootnote
                context.coordinator.onOpenTableOfContents = onOpenTableOfContents
                // Only for text that genuinely came from elsewhere. A value equal to
                // what the view holds needs nothing; an echo of what this editor
                // published, or anything at all mid-composition, must not touch the
                // buffer. See EditorTextArrival.
                let arrival = EditorTextArrival.decide(
                    incoming: text,
                    buffer: view.string,
                    published: context.coordinator.published,
                    isComposing: view.hasMarkedText())
                switch arrival {
                case .external:
                    context.coordinator.replace(text, in: view)
                case .upToDate, .echo, .composing:
                    // Nothing. The buffer is either already right or is the input
                    // method's until it commits — see EditorTextArrival for what that
                    // deliberately gives up.
                    break
                }
                // Through the scroll view's inset rather than the text view's frame: the
                // editor keeps its size, so nothing above it moves, and scrolling —
                // including the caret reveal AppKit does while typing — stays clear of
                // whatever the composer draws over the bottom.
                //
                // The slack is added to it, and is the part that keeps the last line
                // steady. What was reported after the clamp came out: on the last line
                // with nothing below it, a backspace moves the view slightly up, and a
                // space moves it up to that same place and then back to the caret. The
                // same place for both is the giveaway — it is the document's maximum
                // scroll offset. AppKit reaches for that maximum against a height TextKit
                // has not finished recalculating, pulls the origin up to it, and then
                // reveals the caret again. Nothing in this file asks for either move.
                //
                // A viewport that can scroll a few lines past the end is never pressed
                // against that maximum while somebody is writing at it, so a height that
                // is briefly a line short no longer invalidates where they are. It is also
                // what a text editor should do at the end of a document: the last line
                // does not have to be typed against the bottom of the window.
                let reserved = bottomInset + Self.trailingSlack
                if scroll.contentInsets.bottom != reserved {
                    scroll.contentInsets = NSEdgeInsets(
                        top: 0, left: 0, bottom: reserved, right: 0)
                    // `scrollerInsets` is left alone deliberately: it is relative to the
                    // content inset, so the scroller stops where the reserved space
                    // begins — which is where it should stop, rather than running on
                    // behind whatever is drawn there.
                }
            }

            /// How far past the end of the document the view may scroll.
            ///
            /// Three lines: enough that a height TextKit is still recalculating cannot make
            /// the current offset invalid, which is what was moving the last line, and not
            /// so much that the end of a post looks like it fell off the page.
            private static var trailingSlack: CGFloat { MarkdownAttributes.bodySize * 3 }

            func makeCoordinator() -> Coordinator {
                Coordinator(
                    text: $text,
                    accent: NSColor(PlusTheme.accent),
                    onOpenFootnote: onOpenFootnote,
                    onOpenTableOfContents: onOpenTableOfContents)
            }
        }

        @MainActor
        fileprivate final class Coordinator: NSObject, NSTextViewDelegate {
            var text: Binding<String>
            var accent: NSColor
            var onOpenFootnote: (String, String) -> Void
            var onOpenTableOfContents: () -> Void
            private var applyingProgrammaticEdit = false
            private var revision = 0
            private var titleTask: Task<Void, Never>?
            /// Values the buffer and the binding have recently agreed on — what this
            /// editor published, and what it accepted from outside. It is what lets the
            /// next SwiftUI update tell its own echo from a value someone else set.
            ///
            /// A few of them, newest last, because an update can run from a body SwiftUI
            /// evaluated several keystrokes ago. Bounded because it is a guard against
            /// staleness, not a history.
            private(set) var published: [String] = []
            private static let publishedMemory = 8

            init(
                text: Binding<String>,
                accent: NSColor,
                onOpenFootnote: @escaping (String, String) -> Void,
                onOpenTableOfContents: @escaping () -> Void
            ) {
                self.text = text
                self.accent = accent
                self.onOpenFootnote = onOpenFootnote
                self.onOpenTableOfContents = onOpenTableOfContents
            }

            /// Replaces the whole document, for text that came from outside the view.
            ///
            /// `setAttributedString` collapses the selection and leaves the clip view
            /// scrolled against the old document's height. Harmless while the editor is
            /// being created and disruptive on a live one, so where the writer was is put
            /// back afterwards — clamped, because the new text may be shorter.
            func replace(_ source: String, in view: NSTextView) {
                guard let storage = view.textStorage else { return }
                let selection = view.selectedRange()
                let origin = view.enclosingScrollView?.contentView.bounds.origin
                storage.setAttributedString(MarkdownAttributes.attributed(source, accent: accent))
                record(source)
                // A different document. Anything still in flight belongs to the old one:
                // the URL-title resolution checks this before editing, and a stale value
                // here would let it write into text it never read.
                revision += 1
                titleTask?.cancel()
                titleTask = nil
                let limit = storage.length
                let location = min(selection.location, limit)
                view.setSelectedRange(
                    NSRange(location: location, length: min(selection.length, limit - location)))
                if let origin, let scroll = view.enclosingScrollView {
                    scroll.layoutSubtreeIfNeeded()
                    scroll.contentView.scroll(to: origin)
                    constrainViewport(of: scroll)
                }
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
                MarkdownAttributes.restyleChangedAttributes(storage, accent: accent)
                storage.endEditing()

                if view.selectedRange() != selection {
                    let limit = storage.length
                    view.setSelectedRange(
                        NSRange(
                            location: min(selection.location, limit),
                            length: min(selection.length, limit - min(selection.location, limit))))
                }
                updateTypingAttributes(in: view)
                finishLayout(of: view)
            }

            /// Lays out what the edit invalidated, before anything can act on an estimate of
            /// it.
            ///
            /// This is what was moving the last line, and the app's own log named it. Per
            /// keystroke: the document was 957.5pt tall, the writer was at 584.5, and after
            /// the change the height was reported as 837.5 — under which 584.5 is past the
            /// end, so the clip view was clamped up to 455.5, which is exactly
            /// 837.5 − 424 (the viewport) + 42 (the reserved inset). One run-loop turn later
            /// the height was 991.5, under which the writer's position had been valid all
            /// along, and AppKit scrolled the caret back into view with an animation. That
            /// animation is what reads as the scroll shaking.
            ///
            /// 837.5 was never the document's height. It is TextKit's estimate for the part
            /// it had not laid out yet, and nothing downstream can tell an estimate from a
            /// measurement. So the estimate is not allowed to exist: the layout is finished
            /// here, inside the change, while the only thing that has happened is an edit
            /// the writer made.
            ///
            /// The cost is bounded by what the edit invalidated, because TextKit keeps the
            /// fragments it has already laid out. Measured on this pipeline: after the first
            /// full pass — which `makeNSView` gets out of the way when the editor is
            /// created — a keystroke costs 0.1ms in a 500-word post, 0.45ms at 2,000 words
            /// and 0.98ms at 8,000. The estimates it replaces were about 10% short of the
            /// real height at every size, which is the size of the mistake the scroll was
            /// being clamped to.
            func finishLayout(of view: NSTextView) {
                if let layout = view.textLayoutManager {
                    layout.ensureLayout(for: layout.documentRange)
                } else if let manager = view.layoutManager, let container = view.textContainer {
                    // Only reached on a view that is already using TextKit 1; asking a
                    // TextKit 2 view for this would be what moved it there.
                    manager.ensureLayout(for: container)
                }
            }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                guard !applyingProgrammaticEdit else { return }
                revision += 1
                publish(view.string)
                restyle(view)
                // Nothing is scrolled for a keystroke, and nothing is clamped either.
                // AppKit reveals the caret for the event it is handling, which it knows
                // and this does not.
                //
                // A clamp used to run here after any whitespace, on the theory that the
                // restyle's paragraph-style delta could leave the clip view scrolled
                // against the previous document height. Measured on the last line of a
                // document with nothing below it — the one place a clamp can do anything,
                // because it is the only place the origin is at its limit — that clamp was
                // the oscillation: the viewport cycled through three positions about 70pt
                // apart, once per keystroke, while the same typing in the middle of a
                // document never moved it at all. Removing it leaves the origin fixed, and
                // the blank area the clamp was written for does not come back: the gap
                // under the last line measures the same 14pt either way.
            }

            /// Mirrors the buffer into the binding, remembering what was sent.
            ///
            /// The record is what lets the next SwiftUI update tell this editor's own
            /// value coming back from a value someone else set.
            private func publish(_ value: String) {
                record(value)
                text.wrappedValue = value
            }

            /// Notes a value the buffer and the binding now agree on.
            private func record(_ value: String) {
                published.append(value)
                if published.count > Self.publishedMemory { published.removeFirst() }
            }

            func textView(
                _ textView: NSTextView,
                shouldChangeTextIn affectedCharRange: NSRange,
                replacementString: String?
            ) -> Bool {
                guard !applyingProgrammaticEdit, textView.markedRange().length == 0,
                    let replacementString
                else { return true }
                if replacementString == "\n" {
                    apply(
                        { source, _ in
                            PlusMarkdownEdit.breakLine(
                                source, selection: affectedCharRange, kind: .paragraph)
                        },
                        to: textView)
                    return false
                }
                if let url = pastedURL(replacementString),
                   !isMarkdownDestination(in: textView.string, selection: affectedCharRange)
                {
                    paste(url, selection: affectedCharRange, into: textView)
                    return false
                }
                return true
            }

            func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                if commandSelector == #selector(NSResponder.insertLineBreak(_:))
                    || (commandSelector == #selector(NSResponder.insertNewline(_:))
                        && NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                {
                    apply(
                        { PlusMarkdownEdit.breakLine($0, selection: $1, kind: .line) },
                        to: textView)
                    return true
                }
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    apply(
                        { PlusMarkdownEdit.breakLine($0, selection: $1, kind: .paragraph) },
                        to: textView)
                    return true
                }
                return false
            }

            func textView(
                _ textView: NSTextView,
                clickedOnLink link: Any,
                at charIndex: Int
            ) -> Bool {
                guard let url = link as? URL else { return false }
                switch (url.scheme, url.host) {
                case ("nook-toc", _):
                    onOpenTableOfContents()
                    return true
                case ("nook-footnote", "reference"):
                    guard let label = url.pathComponents.dropFirst().first else {
                        return false
                    }
                    onOpenFootnote(label, textView.string)
                    return true
                default:
                    return false
                }
            }

            /// Moving the caret between a heading and body text changes what an IME
            /// should draw before it commits its marked text. This is AppKit-only:
            /// UIKit manages marked-text attributes independently and already renders
            /// Korean composition correctly.
            func textViewDidChangeSelection(_ notification: Notification) {
                guard let view = notification.object as? NSTextView,
                    view.markedRange().length == 0
                else { return }
                updateTypingAttributes(in: view)
            }

            private func updateTypingAttributes(in view: NSTextView) {
                view.typingAttributes = MarkdownAttributes.typingAttributes(
                    for: view.string,
                    atUTF16Offset: view.selectedRange().location,
                    accent: accent)
            }

            /// See the iOS coordinator: routed through the text view's own editing API
            /// so one button press is one undo step.
            func apply(
                _ makeEdit: (String, NSRange) -> PlusMarkdownEdit.Edit, to view: NSTextView
            ) {
                let edit = makeEdit(view.string, view.selectedRange())
                apply(edit, to: view)
            }

            private func apply(_ edit: PlusMarkdownEdit.Edit, to view: NSTextView) {
                // The documented order for a programmatic edit: ask, change the
                // storage, then report. `shouldChangeText` is what opens the undo
                // grouping, so one button press stays one undo step.
                applyingProgrammaticEdit = true
                guard view.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
                    applyingProgrammaticEdit = false
                    return
                }
                view.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
                view.didChangeText()
                view.setSelectedRange(edit.selection)
                applyingProgrammaticEdit = false
                revision += 1
                publish(view.string)
                restyle(view)
                // The caret was moved by the edit rather than by the writer, so revealing
                // it is this path's job; a keystroke's is AppKit's.
                settleViewport(in: view, revealing: edit.selection, atRevision: revision)
            }

            func apply(
                _ makeTransaction: (String, NSRange) -> PlusMarkdownEdit.Transaction,
                to view: NSTextView
            ) {
                let transaction = makeTransaction(view.string, view.selectedRange())
                let ordered = transaction.replacements.sorted {
                    if $0.range.location == $1.range.location {
                        return $0.range.length > $1.range.length
                    }
                    return $0.range.location > $1.range.location
                }
                applyingProgrammaticEdit = true
                view.undoManager?.beginUndoGrouping()
                for replacement in ordered {
                    guard view.shouldChangeText(
                        in: replacement.range, replacementString: replacement.text)
                    else { continue }
                    view.textStorage?.replaceCharacters(in: replacement.range, with: replacement.text)
                    view.didChangeText()
                }
                view.undoManager?.endUndoGrouping()
                view.setSelectedRange(transaction.selection)
                applyingProgrammaticEdit = false
                revision += 1
                publish(view.string)
                restyle(view)
                // Same as the single-edit path: the transaction chose where the caret
                // ends up, so that is what gets revealed, and only if it is off screen.
                settleViewport(in: view, revealing: transaction.selection, atRevision: revision)
            }

            /// Keeps the scroll view usable after an edit, without taking the scroll away
            /// from the writer.
            ///
            /// AppKit updates an `NSTextView`'s document height lazily. Return is routed
            /// through ``apply(_:to:)`` so Markdown lists and hard breaks can choose
            /// their replacement text; when that replacement splits a paragraph, its
            /// paragraph-style delta can leave the clip view using bounds calculated
            /// for the previous height for one frame. That exposes a large blank area
            /// until the first manual scroll constrains the bounds again.
            ///
            /// Two things happen here and nothing else. The clip view is clamped, now and
            /// again on the next run-loop turn once TextKit has committed its geometry —
            /// a no-op whenever the bounds were already valid. And a selection the writer
            /// did not move themselves is revealed, which `scrollRangeToVisible` does by
            /// the minimum amount and not at all when it is already on screen.
            ///
            /// What used to also happen was restoring the pre-edit origin *and* then
            /// revealing the caret, which moved the viewport twice for one keypress and
            /// read as the scroll fighting the writer.
            ///
            /// Only edits the writer made with a button or with Return come through here.
            /// Typing does not, and must not: the clamp is measurably the wrong thing on
            /// the last line of a document, where it is also the only thing that can act at
            /// all. AppKit reveals the caret for a keystroke by itself, and better, because
            /// it knows which event it is responding to.
            private func settleViewport(
                in view: NSTextView,
                revealing selection: NSRange,
                atRevision expectedRevision: Int
            ) {
                guard let scroll = view.enclosingScrollView else { return }
                scroll.layoutSubtreeIfNeeded()
                constrainViewport(of: scroll)
                view.scrollRangeToVisible(selection)
                constrainViewport(of: scroll)

                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.revision == expectedRevision,
                        let scroll = view.enclosingScrollView
                    else { return }
                    scroll.layoutSubtreeIfNeeded()
                    self.constrainViewport(of: scroll)
                    view.needsDisplay = true
                }
            }

            private func constrainViewport(of scroll: NSScrollView) {
                let clip = scroll.contentView
                let constrained = clip.constrainBoundsRect(clip.bounds)
                if constrained.origin != clip.bounds.origin {
                    clip.scroll(to: constrained.origin)
                }
                scroll.reflectScrolledClipView(clip)
            }

            private func paste(_ url: URL, selection: NSRange, into view: NSTextView) {
                let paste = PlusMarkdownEdit.pasteURL(url, into: view.string, selection: selection)
                let shouldResolve = selection.length == 0
                apply(paste.edit, to: view)
                guard shouldResolve else { return }
                let expectedRevision = revision
                let expectedLabel = (view.string as NSString).substring(with: paste.labelRange)
                titleTask?.cancel()
                titleTask = Task { [weak self, weak view] in
                    guard let title = await PlusLinkTitleResolver.shared.title(for: url),
                        !title.isEmpty,
                        let self,
                        let view,
                        self.revision == expectedRevision,
                        NSMaxRange(paste.labelRange) <= (view.string as NSString).length,
                        (view.string as NSString).substring(with: paste.labelRange) == expectedLabel
                    else { return }
                    var edit = PlusMarkdownEdit.linkTitle(title, labelRange: paste.labelRange)
                    let selection = view.selectedRange()
                    let delta = (edit.replacement as NSString).length - edit.range.length
                    edit.selection = selection.location >= edit.range.upperBound
                        ? NSRange(location: selection.location + delta, length: selection.length)
                        : selection
                    self.apply(edit, to: view)
                }
            }

            private func pastedURL(_ replacement: String) -> URL? {
                guard replacement == replacement.trimmingCharacters(in: .whitespacesAndNewlines),
                    !replacement.contains(where: \.isWhitespace),
                    let url = URL(string: replacement),
                    ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                    url.host != nil
                else { return nil }
                return url
            }

            private func isMarkdownDestination(in text: String, selection: NSRange) -> Bool {
                let ns = text as NSString
                let before = ns.substring(to: min(selection.location, ns.length)) as NSString
                let open = before.range(of: "](", options: .backwards)
                guard open.location != NSNotFound else { return false }
                return !before.substring(from: open.location + open.length).contains(")")
            }
        }
    }
#endif
