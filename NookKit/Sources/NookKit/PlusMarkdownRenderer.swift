import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Publication Markdown -> HTML -> the shared native reader. Studio consumes
/// Markdown directly from the PDS, not RSS or a Legibility extraction. Keep
/// authoring extensions here, separate from the translation-only block parser.
enum PlusMarkdownRenderer {
    private typealias Node = UnsafeMutablePointer<cmark_node>
    static func html(from markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_FOOTNOTES | CMARK_OPT_SMART
        guard let parser = cmark_parser_new(options) else { return escaped(markdown) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let root = cmark_parser_finish(parser) else { return escaped(markdown) }
        defer { cmark_node_free(root) }

        let nodes = descendants(of: root)
        let headings = nodes.filter { cmark_node_get_type($0) == CMARK_NODE_HEADING }
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let markers = nodes.filter { node in
            guard cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH,
                  cmark_node_parent(node) == root,
                  cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
                  let child = cmark_node_first_child(node),
                  cmark_node_get_type(child) == CMARK_NODE_TEXT,
                  cmark_node_next(child) == nil else { return false }
            let line = Int(cmark_node_get_start_line(node)) - 1
            // Source spelling matters: \[TOC] and `[TOC]` are literal examples.
            return lines.indices.contains(line)
                && lines[line].trimmingCharacters(in: .whitespaces).uppercased() == "[TOC]"
        }

        // Retain the preview's supported inline HTML without enabling cmark's
        // UNSAFE option (which would also allow javascript: links).
        for node in nodes {
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_HTML_INLINE, let literal = cmark_node_get_literal(node) {
                replace(node, type: CMARK_NODE_CUSTOM_INLINE,
                        opening: MarkdownNativeParser.safeInlineHTML(String(cString: literal)))
            } else if type == CMARK_NODE_HTML_BLOCK, let literal = cmark_node_get_literal(node) {
                let raw = String(cString: literal)
                let lower = raw.lowercased()
                if !["<script", "<style", "<iframe"].contains(where: lower.contains) {
                    replace(node, type: CMARK_NODE_CUSTOM_BLOCK, opening: raw)
                }
            }
        }

        var used = Set<String>()
        var entries: [Heading] = []
        for node in headings {
            let title = plainText(in: node)
            let level = Int(cmark_node_get_heading_level(node))
            let base = PlusMarkdownDocumentIndex.anchor(for: title)
            // cmark owns fn-/fnref- ids. Keep headings out of that namespace.
            let safeBase = base.hasPrefix("fn-") || base.hasPrefix("fnref-") ? "heading-\(base)" : base
            var anchor = safeBase
            var suffix = 2
            while !used.insert(anchor).inserted {
                anchor = "\(safeBase)-\(suffix)"
                suffix += 1
            }
            entries.append(Heading(level: level, title: title, anchor: anchor))
            replace(node, type: CMARK_NODE_CUSTOM_BLOCK,
                    opening: "<h\(level) id=\"\(anchor)\">", closing: "</h\(level)>")
        }
        var index = 0
        let toc = tableOfContents(entries, index: &index, parentLevel: 0)
        for marker in markers {
            replace(marker, type: CMARK_NODE_CUSTOM_BLOCK, opening: toc, keepingChildren: false)
        }

        guard let rendered = cmark_render_html(root, options, cmark_parser_get_syntax_extensions(parser)) else {
            return escaped(markdown)
        }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    private struct Heading {
        let level: Int
        let title: String
        let anchor: String
    }

    private static func tableOfContents(_ entries: [Heading], index: inout Int, parentLevel: Int) -> String {
        guard index < entries.count else { return "" }
        var html = "<ul>"
        while index < entries.count, entries[index].level > parentLevel {
            let entry = entries[index]
            index += 1
            let fragment = entry.anchor.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.anchor
            html += "<li><a href=\"#\(fragment)\">\(escaped(entry.title))</a>"
            if index < entries.count, entries[index].level > entry.level {
                html += tableOfContents(entries, index: &index, parentLevel: entry.level)
            }
            html += "</li>"
        }
        return html + "</ul>"
    }

    private static func descendants(of node: Node) -> [Node] {
        guard let iterator = cmark_iter_new(node) else { return [] }
        defer { cmark_iter_free(iterator) }
        var nodes: [Node] = []
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            if event == CMARK_EVENT_ENTER, let current = cmark_iter_get_node(iterator) {
                nodes.append(current)
            }
        }
        return nodes
    }

    private static func plainText(in node: Node) -> String {
        descendants(of: node).compactMap { child -> String? in
            let type = cmark_node_get_type(child)
            if type == CMARK_NODE_SOFTBREAK || type == CMARK_NODE_LINEBREAK { return " " }
            guard type == CMARK_NODE_TEXT || type == CMARK_NODE_CODE,
                  let text = cmark_node_get_literal(child) else { return nil }
            return String(cString: text)
        }.joined()
    }

    private static func replace(
        _ node: Node, type: cmark_node_type, opening: String,
        closing: String = "", keepingChildren: Bool = true
    ) {
        guard let replacement = cmark_node_new(type) else { return }
        cmark_node_set_on_enter(replacement, opening)
        cmark_node_set_on_exit(replacement, closing)
        cmark_node_insert_before(node, replacement)
        if keepingChildren {
            while let child = cmark_node_first_child(node) {
                cmark_node_unlink(child)
                cmark_node_append_child(replacement, child)
            }
        }
        cmark_node_unlink(node)
        cmark_node_free(node)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
