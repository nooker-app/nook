import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Off-main-capable importer for the whitelisted subset of inline article HTML.
///
/// `HTMLContentText`'s classic path routes every text fragment through the
/// platform's WebKit HTML importer, which is main-thread-only and costs several
/// milliseconds per block — the last per-article main-thread text cost in the
/// reader. This renderer produces the same final attributes (fonts via the
/// shared `HTMLContentText.finalBodyFont`/`finalCodeFont`, link/code colors,
/// `HTMLTextFlow.normalize` paragraph treatment, and the same
/// `AttributedString(_, including:)` conversion) for the constructs that make
/// up the overwhelming majority of feed text.
///
/// Safety model — the detector IS the renderer: one tokenizer pass either
/// completes with only whitelisted constructs, or returns nil, in which case
/// the caller falls back to the WebKit importer byte-for-byte as before.
/// Anything unrecognized — unknown tags, any `style=` attribute, unknown
/// entities, malformed nesting, comments, strong-RTL content — bails. Exotic
/// HTML therefore cannot regress; it just keeps its old (main-thread) path.
///
/// Escape hatch: set the `nativeInlineHTMLRendererDisabled` UserDefaults bool
/// and relaunch to force the classic path for every fragment. Read once per
/// launch so a given (html, baseSize, bold) cache key always maps to one
/// renderer's output within a process (`HTMLAttributedCache` is per-launch).
enum NativeInlineHTMLRenderer {
    static let disabledDefaultsKey = "nativeInlineHTMLRendererDisabled"
    static let isDisabled = UserDefaults.standard.bool(forKey: disabledDefaultsKey)

    /// Fragments beyond this bail (allocation bound); they keep today's cost.
    private static let maxFragmentBytes = 262_144
    /// Nesting beyond this is not article prose; bail.
    private static let maxTagDepth = 32

    /// Renders a *prepared* fragment (after `HTMLTextFlow.preparedHTML`, so
    /// `<br>` is already U+2028). Returns nil for anything outside the
    /// whitelist, malformed input, or an empty result — the caller must then
    /// use the WebKit importer.
    static func importPrepared(
        _ prepared: String,
        baseSize: CGFloat,
        bold: Bool,
        typography: ReaderTypography = .platformDefault
    ) -> AttributedString? {
        guard prepared.utf8.count <= maxFragmentBytes else { return nil }
        guard !containsStrongRTL(prepared) else { return nil }
        guard let paragraphs = tokenize(prepared), !paragraphs.isEmpty else { return nil }

        let mutable = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 {
                mutable.append(NSAttributedString(string: "\n", attributes: attributes(for: Style(), baseSize: baseSize, boldParam: bold, design: typography.design)))
            }
            for run in paragraph {
                mutable.append(NSAttributedString(
                    string: run.text,
                    attributes: attributes(for: run.style, baseSize: baseSize, boldParam: bold, design: typography.design)
                ))
            }
        }

        HTMLTextFlow.normalize(mutable, baseSize: baseSize)
        HTMLTextFlow.applyKern(mutable, typography: typography)
        guard mutable.length > 0 else { return nil }
        #if canImport(AppKit)
        return try? AttributedString(mutable, including: \.appKit)
        #else
        return try? AttributedString(mutable, including: \.uiKit)
        #endif
    }

    // MARK: - Attribute production

    /// Mirrors the WebKit tail exactly: every character carries a `.font` and a
    /// `.foregroundColor`; links add `.link` + accent color + soft underline;
    /// code uses the shared mono font and the pink tint, which wins over the
    /// link color (the tail applies pink after `styleLinks`).
    private static func attributes(for style: Style, baseSize: CGFloat, boldParam: Bool, design: ReaderFont) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        let isBold = style.bold || boldParam

        #if canImport(AppKit)
        let linkColor = NSColor.controlAccentColor
        let plainColor = NSColor.labelColor
        let codeColor = NSColor.systemPink
        #else
        let linkColor = UIColor.tintColor
        let plainColor = UIColor.label
        let codeColor = UIColor.systemPink
        #endif

        if style.code {
            attrs[.font] = HTMLContentText.finalCodeFont(baseSize: baseSize, bold: isBold)
            attrs[.foregroundColor] = codeColor
        } else {
            attrs[.font] = HTMLContentText.finalBodyFont(baseSize: baseSize, bold: isBold, italic: style.italic, design: design)
            attrs[.foregroundColor] = plainColor
        }
        if let link = style.link {
            attrs[.link] = link
            if !style.code { attrs[.foregroundColor] = linkColor }
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = linkColor.withAlphaComponent(0.4)
        }
        if let script = style.script {
            // Smaller, and offset by a fraction of the *body* size so the shift is
            // proportional to the text it sits beside rather than to itself.
            let scaled = max(baseSize * 0.7, 9)
            attrs[.font] = HTMLContentText.finalBodyFont(
                baseSize: scaled, bold: isBold, italic: style.italic, design: design)
            attrs[.baselineOffset] = script == .superscript ? baseSize * 0.34 : -baseSize * 0.16
            // A marker is small; the underline crowds it and reads as a smudge at
            // body sizes. Colour alone carries that it is tappable, which is what
            // the web page does too.
            if style.link != nil {
                attrs[.underlineStyle] = 0
            }
        }
        return attrs
    }

    // MARK: - Tokenizer

    private struct Style: Equatable {
        var bold = false
        var italic = false
        var code = false
        var link: URL? = nil
        /// Raised or lowered text. A footnote marker is a `<sup>`, and without
        /// this the whole inline run fell back and the marker read as body text
        /// sitting in the middle of a sentence.
        var script: Script? = nil

        enum Script: Equatable {
            case superscript
            case subscript_
        }
    }

    private struct Run {
        var text: String
        var style: Style
    }

    private typealias Paragraph = [Run]

    /// Whitelisted tags and the attributes silently ignored on them (classes
    /// have no effect without a stylesheet; the importer drops them too). Any
    /// other tag, or any other attribute — `style=` above all — bails.
    private static let ignorableAttributes: Set<String> = ["class", "id"]
    /// `role` is here because the footnote markup declares one — `doc-noteref` on
    /// the marker, `doc-backlink` on the way back. It is meaning for a screen reader
    /// and nothing for this renderer to act on, and rejecting it bailed the entire
    /// paragraph to the WebKit path: the marker rendered as body text and nothing was
    /// tappable, while a contents list, whose links carry no role, worked.
    private static let ignorableAnchorAttributes: Set<String> = ["class", "id", "title", "rel", "target", "name", "role"]
    /// `role` joins the list for sup/sub: the footnote markup carries
    /// `role="doc-noteref"`, which is meaning for a screen reader and nothing for
    /// this renderer to act on.
    private static let ignorableSupAttributes: Set<String> = ["class", "id", "role"]

    /// One pass: parses, validates against the whitelist, and produces
    /// whitespace-collapsed styled runs grouped into paragraphs. Any deviation
    /// returns nil. Two structures are accepted: a pure inline fragment (no
    /// `<p>`), or a sequence of top-level `<p>…</p>` paragraphs with only
    /// whitespace between them — mixing loose text and `<p>` bails (WebKit's
    /// implied-paragraph recovery is not replicated).
    private static func tokenize(_ input: String) -> [Paragraph]? {
        var paragraphs: [Paragraph] = []
        var builder = ParagraphBuilder()
        var style = Style()
        var stack: [(name: String, styleBefore: Style)] = []
        var usedParagraphTags = false
        var inParagraph = false
        var sawLooseContent = false

        let scalars = Array(input.unicodeScalars)
        var i = 0

        func finishParagraph() {
            paragraphs.append(builder.finish())
            builder = ParagraphBuilder()
        }

        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "<" {
                guard let tag = parseTag(scalars, at: &i) else { return nil }
                let name = tag.name
                if tag.isClose {
                    guard let top = stack.last, top.name == name else { return nil }
                    stack.removeLast()
                    style = top.styleBefore
                    if name == "p" {
                        guard inParagraph, stack.isEmpty else { return nil }
                        inParagraph = false
                        finishParagraph()
                    }
                    continue
                }
                guard stack.count < maxTagDepth, tag.selfClosing == false else { return nil }
                switch name {
                case "p":
                    // Top-level only, never nested, never mixed with loose text.
                    guard stack.isEmpty, !inParagraph, !sawLooseContent else { return nil }
                    usedParagraphTags = true
                    inParagraph = true
                    stack.append((name, style))
                    guard attributesAreIgnorable(tag.attributes, allowed: ignorableAttributes) else { return nil }
                case "b", "strong":
                    guard attributesAreIgnorable(tag.attributes, allowed: ignorableAttributes) else { return nil }
                    stack.append((name, style))
                    style.bold = true
                case "i", "em":
                    guard attributesAreIgnorable(tag.attributes, allowed: ignorableAttributes) else { return nil }
                    stack.append((name, style))
                    style.italic = true
                case "code":
                    guard attributesAreIgnorable(tag.attributes, allowed: ignorableAttributes) else { return nil }
                    stack.append((name, style))
                    style.code = true
                case "span":
                    guard attributesAreIgnorable(tag.attributes, allowed: ignorableAttributes) else { return nil }
                    stack.append((name, style))
                case "sup", "sub":
                    // `id` is allowed here and ignored: a footnote marker carries one
                    // so the note can link back to it, and the anchor table built by
                    // the parser is what resolves that — not this attribute.
                    guard attributesAreIgnorable(tag.attributes, allowed: ignorableSupAttributes),
                        style.script == nil
                    else { return nil }
                    stack.append((name, style))
                    style.script = name == "sup" ? .superscript : .subscript_
                case "a":
                    // Nested anchors are well-formed to the stack but WebKit
                    // auto-closes the outer one — semantics we don't replicate.
                    guard style.link == nil,
                          let url = anchorURL(from: tag.attributes) else { return nil }
                    stack.append((name, style))
                    style.link = url
                default:
                    return nil
                }
                continue
            }

            // Text content (entities decoded, whitespace handled by the builder).
            let character: Character
            if scalar == "&" {
                guard let decoded = parseEntity(scalars, at: &i) else { return nil }
                switch decoded {
                case .character(let c): character = c
                case .literalAmpersand:
                    character = "&"
                    i += 1
                }
            } else {
                character = Character(scalar)
                i += 1
            }

            // Content placement rules for the paragraph model.
            if usedParagraphTags && !inParagraph {
                // Between/after <p> blocks only whitespace is tolerated.
                if isCollapsibleWhitespace(character) { continue }
                return nil
            }
            if !usedParagraphTags, !isCollapsibleWhitespace(character) {
                sawLooseContent = true
            }
            builder.append(character, style: style)
        }

        guard stack.isEmpty else { return nil }
        if !usedParagraphTags {
            finishParagraph()
        } else if inParagraph {
            return nil
        }
        // Entity decoding never yields entity-able text again (no double decode),
        // matching the strict single-decode the importer performs.
        return paragraphs
    }

    /// Accumulates one paragraph's runs with CSS `white-space: normal`
    /// collapsing: whitespace runs become one space (attributed with the style
    /// active when the run began), dropped at the paragraph edges. U+2028 (the
    /// pre-substituted `<br>`) and NBSP (U+00A0) are content, never collapsed —
    /// the WebKit importer keeps regular spaces around U+2028, verified by the
    /// differential corpus.
    private struct ParagraphBuilder {
        private var runs: [Run] = []
        private var pendingSpaceStyle: Style?
        private var atBoundary = true

        mutating func append(_ character: Character, style: Style) {
            if isCollapsibleWhitespace(character) {
                if !atBoundary, pendingSpaceStyle == nil { pendingSpaceStyle = style }
                return
            }
            if let spaceStyle = pendingSpaceStyle {
                emit(" ", style: spaceStyle)
                pendingSpaceStyle = nil
            }
            emit(String(character), style: style)
            atBoundary = false
        }

        private mutating func emit(_ text: String, style: Style) {
            if var last = runs.last, last.style == style {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(text: text, style: style))
            }
        }

        func finish() -> Paragraph {
            runs
        }
    }

    private static func isCollapsibleWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r" || character == "\u{0C}"
    }

    // MARK: Tag parsing

    private struct Tag {
        var name: String
        var isClose: Bool
        var selfClosing: Bool
        var attributes: [(name: String, value: String?)]
    }

    /// Parses a tag starting at `i` (which points at `<`). Advances `i` past
    /// the closing `>`. Returns nil on anything that isn't a plain, well-formed
    /// tag — including comments, doctypes, and processing instructions.
    private static func parseTag(_ scalars: [Unicode.Scalar], at i: inout Int) -> Tag? {
        var j = i + 1
        guard j < scalars.count else { return nil }
        var isClose = false
        if scalars[j] == "/" {
            isClose = true
            j += 1
        }
        guard j < scalars.count, isASCIILetter(scalars[j]) else { return nil }
        var name = ""
        while j < scalars.count, isASCIILetter(scalars[j]) || isASCIIDigit(scalars[j]) {
            name.unicodeScalars.append(lowercased(scalars[j]))
            j += 1
        }

        var attributes: [(name: String, value: String?)] = []
        var selfClosing = false
        while true {
            // Skip whitespace.
            while j < scalars.count, isTagWhitespace(scalars[j]) { j += 1 }
            guard j < scalars.count else { return nil }
            if scalars[j] == ">" {
                j += 1
                break
            }
            if scalars[j] == "/" {
                // Only valid as the "/>" terminator.
                guard j + 1 < scalars.count, scalars[j + 1] == ">" else { return nil }
                selfClosing = true
                j += 2
                break
            }
            guard !isClose else { return nil }
            // Attribute name.
            guard isASCIILetter(scalars[j]) else { return nil }
            var attrName = ""
            while j < scalars.count, isASCIILetter(scalars[j]) || isASCIIDigit(scalars[j]) || scalars[j] == "-" || scalars[j] == "_" {
                attrName.unicodeScalars.append(lowercased(scalars[j]))
                j += 1
            }
            while j < scalars.count, isTagWhitespace(scalars[j]) { j += 1 }
            guard j < scalars.count else { return nil }
            if scalars[j] != "=" {
                attributes.append((attrName, nil))
                continue
            }
            j += 1
            while j < scalars.count, isTagWhitespace(scalars[j]) { j += 1 }
            guard j < scalars.count else { return nil }
            var value = ""
            if scalars[j] == "\"" || scalars[j] == "'" {
                let quote = scalars[j]
                j += 1
                while j < scalars.count, scalars[j] != quote {
                    value.unicodeScalars.append(scalars[j])
                    j += 1
                }
                guard j < scalars.count else { return nil }
                j += 1
            } else {
                while j < scalars.count, !isTagWhitespace(scalars[j]), scalars[j] != ">" {
                    if scalars[j] == "/" || scalars[j] == "\"" || scalars[j] == "'" || scalars[j] == "<" { return nil }
                    value.unicodeScalars.append(scalars[j])
                    j += 1
                }
            }
            attributes.append((attrName, value))
        }
        i = j
        return Tag(name: name, isClose: isClose, selfClosing: selfClosing, attributes: attributes)
    }

    private static func attributesAreIgnorable(_ attributes: [(name: String, value: String?)], allowed: Set<String>) -> Bool {
        attributes.allSatisfy { allowed.contains($0.name) }
    }

    /// A single, parseable `href` (other cosmetic anchor attributes ignored).
    /// Entities inside the href are decoded (`&amp;` in query strings is
    /// ubiquitous). Anything else — missing/duplicate/unparseable href, any
    /// non-cosmetic attribute — bails rather than guessing WebKit's laundering.
    private static func anchorURL(from attributes: [(name: String, value: String?)]) -> URL? {
        var href: String?
        for attribute in attributes {
            if attribute.name == "href" {
                guard href == nil, let value = attribute.value else { return nil }
                href = value
            } else if !ignorableAnchorAttributes.contains(attribute.name) {
                return nil
            }
        }
        guard var href, !href.isEmpty else { return nil }
        if href.contains("&") {
            guard let decoded = decodeEntitiesStrictly(href) else { return nil }
            href = decoded
        }
        // A fragment is not a place to go; it is a place in this document. The
        // scheme rule below exists to stop scheme-less *external* links being
        // invented here, and an in-document jump is not that: the footnote markers
        // and the table of contents both point this way, and dropping them left a
        // number and a list of headings that looked live and did nothing.
        //
        // Carried as a URL with a scheme of our own so it flows through the same
        // link attribute and the same tap handling as any other link, and so a
        // reader that does not know the scheme simply does nothing with it.
        if href.hasPrefix("#") {
            let fragment = String(href.dropFirst())
            guard !fragment.isEmpty else { return nil }
            return HTMLContentAnchor.url(fragment: fragment)
        }

        // Scheme required: the WebKit importer (run without a baseURL) imports
        // relative and scheme-less hrefs with NO link attribute at all — plain
        // text, no underline. Rendering them as tappable links here would be a
        // visible divergence, so they keep the classic path.
        //
        // WebKit also canonicalizes the URL. Reproduce the one rule the
        // differential corpus pins — a host-only http(s) URL gains a trailing
        // slash — and bail on anything else non-canonical (uppercase scheme or
        // host) rather than guessing the launderer's remaining behavior.
        guard var components = URLComponents(string: href), let scheme = components.scheme else { return nil }
        guard scheme == scheme.lowercased(), (components.host ?? "") == (components.host ?? "").lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            guard components.host?.isEmpty == false else { return nil }
            if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        }
        return components.url
    }

    private static func decodeEntitiesStrictly(_ value: String) -> String? {
        var result = ""
        let scalars = Array(value.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "&" {
                guard let decoded = parseEntity(scalars, at: &i) else { return nil }
                switch decoded {
                case .character(let c): result.append(c)
                case .literalAmpersand:
                    result.append("&")
                    i += 1
                }
            } else {
                result.unicodeScalars.append(scalars[i])
                i += 1
            }
        }
        return result
    }

    // MARK: Entities

    private enum DecodedEntity {
        case character(Character)
        /// A bare `&` that visibly can't start an entity (followed by
        /// whitespace, `<`, or end) — emitted literally, like the importer.
        case literalAmpersand
    }

    /// Strict entity decoding: numeric (`&#…;`/`&#x…;`) with valid scalars, or
    /// a curated named set — every name here has a differential-corpus entry.
    /// An `&` followed by `#`/alphanumerics that does NOT strictly parse bails
    /// the whole render (nil): WebKit decodes some legacy entities without a
    /// trailing semicolon, and guessing which would risk silent divergence.
    private static let namedEntities: [String: Character] = [
        "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&",
        "nbsp": "\u{00A0}", // NOT a plain space: WebKit imports U+00A0.
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "deg": "\u{00B0}", "times": "\u{00D7}",
    ]

    /// Parses an entity starting at `i` (pointing at `&`). On success advances
    /// `i` past the `;` and returns the character. Returns `.literalAmpersand`
    /// (without advancing) when the `&` can't possibly start an entity. Returns
    /// nil — bail the render — for anything ambiguous or unknown.
    private static func parseEntity(_ scalars: [Unicode.Scalar], at i: inout Int) -> DecodedEntity? {
        let next = i + 1
        guard next < scalars.count else { return .literalAmpersand }
        let first = scalars[next]
        if !(first == "#" || isASCIILetter(first) || isASCIIDigit(first)) {
            return .literalAmpersand
        }
        // Find the terminating ';' within a short window.
        var j = next
        var body = ""
        let limit = min(scalars.count, i + 32)
        while j < limit, scalars[j] != ";" {
            body.unicodeScalars.append(scalars[j])
            j += 1
        }
        guard j < limit, scalars[j] == ";" else { return nil }

        let decoded: Character?
        if body.hasPrefix("#") {
            let token = String(body.dropFirst())
            let scalarValue: UInt32?
            if token.hasPrefix("x") || token.hasPrefix("X") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            // HTML5 remaps numeric references in 0x00 and 0x80–0x9F through
            // Windows-1252 (legacy CMS feeds emit these constantly — &#146; is
            // a curly apostrophe, not the C1 control U+0092). Rather than carry
            // the remap table, bail: WebKit reproduces the spec exactly. Other
            // C0 controls also bail — the importer's handling isn't worth
            // guessing for characters that never appear in honest prose.
            guard let value = scalarValue, value >= 0x20, !(0x7F...0x9F).contains(value) else { return nil }
            decoded = Unicode.Scalar(value).map(Character.init)
        } else {
            decoded = namedEntities[body]
        }
        guard let decoded else { return nil }
        // The strong-RTL gate scans the raw input, which an entity-encoded RTL
        // character (&#x5D0;) bypasses — re-check the decoded scalar here.
        guard !decoded.unicodeScalars.contains(where: isStrongRTLScalar) else { return nil }
        i = j + 1
        return .character(decoded)
    }

    // MARK: Character classes

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }

    private static func isTagWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard (0x41...0x5A).contains(scalar.value) else { return scalar }
        return Unicode.Scalar(scalar.value + 0x20)!
    }

    /// WebKit can set the paragraph's base writing direction from strong-RTL
    /// content (and `HTMLTextFlow.normalize` deliberately preserves it); the
    /// native path can't reproduce that heuristic, so RTL fragments keep the
    /// classic path. Entity-decoded characters re-check via `isStrongRTLScalar`.
    private static func containsStrongRTL(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isStrongRTLScalar)
    }

    private static func isStrongRTLScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x0590...0x08FF).contains(v)        // Hebrew, Arabic, Syriac, …
            || (0xFB1D...0xFDFF).contains(v)        // Hebrew/Arabic presentation forms
            || (0xFE70...0xFEFF).contains(v)        // Arabic presentation forms B
            || v == 0x200F || v == 0x202B || v == 0x202E // RLM, RLE, RLO
            || (0x2066...0x2069).contains(v)        // directional isolates
            || (0x10800...0x10FFF).contains(v)      // historic RTL (Phoenician, Aramaic, …)
            || (0x1E800...0x1EFFF).contains(v)      // Adlam, Rohingya, Arabic Math symbols
    }
}

/// In-document links, carried as URLs so they travel with the ordinary link
/// attribute instead of needing plumbing of their own.
///
/// The scheme is ours and is never opened: the reader recognises it and scrolls,
/// and anything that does not recognise it declines to open an unknown scheme,
/// which is the right failure.
public enum HTMLContentAnchor {
    public static let scheme = "nook-anchor"

    /// A link to the element with this `id` in the same document.
    public static func url(fragment: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        // The id goes in the path rather than the host: ids are case-sensitive and
        // may contain characters a host may not, and `my-post-fn:1` is one of them.
        components.path = "/" + fragment
        return components.url
    }

    /// The id a link points at, or nil when it is an ordinary link.
    public static func fragment(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        let fragment = String(path.dropFirst())
        return fragment.isEmpty ? nil : fragment
    }
}
