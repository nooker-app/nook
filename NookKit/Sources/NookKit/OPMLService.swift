import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A feed entry parsed from an OPML outline, with its declared folder as the
/// category so the import preview can group and label it.
public struct OPMLFeed: Identifiable, Hashable, Sendable {
    public var id: String { feedURL.absoluteString }
    public var title: String
    public var feedURL: URL
    public var siteURL: URL?
    public var category: String?

    public init(title: String, feedURL: URL, siteURL: URL?, category: String?) {
        self.title = title
        self.feedURL = feedURL
        self.siteURL = siteURL
        self.category = category
    }
}

public struct OPMLService: Sendable {
    public init() {}

    public func importFeeds(from fileURL: URL) throws -> [OPMLFeed] {
        let data = try Data(contentsOf: fileURL)
        let parser = OPMLOutlineParser()
        return try parser.parse(data: data)
    }

    public func exportData(for feeds: [Feed]) -> Data {
        // Group by folder so the export round-trips: the import parser reads a
        // feed's folder from its enclosing container <outline>, so a flat list
        // (what this used to emit) dropped every folder on re-import. Ungrouped
        // feeds stay at the top level; each folder becomes a container outline
        // wrapping its feeds. "Feeds" is the reserved top-level sentinel, so
        // `folderName` maps it to "" (no folder).
        let sorted = feeds.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        func feedOutline(_ feed: Feed, indent: String) -> String {
            "\(indent)<outline text=\"\(feed.title.xmlEscaped)\" title=\"\(feed.title.xmlEscaped)\" type=\"rss\" xmlUrl=\"\(feed.feedURL.absoluteString.xmlEscaped)\" htmlUrl=\"\(feed.siteURL.absoluteString.xmlEscaped)\" />"
        }

        var byFolder: [String: [Feed]] = [:]
        for feed in sorted where !feed.folderName.isEmpty {
            byFolder[feed.folderName, default: []].append(feed)
        }
        let folders = byFolder.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var lines = sorted.filter { $0.folderName.isEmpty }.map { feedOutline($0, indent: "    ") }
        for folder in folders {
            lines.append("    <outline text=\"\(folder.xmlEscaped)\" title=\"\(folder.xmlEscaped)\">")
            lines.append(contentsOf: (byFolder[folder] ?? []).map { feedOutline($0, indent: "      ") })
            lines.append("    </outline>")
        }
        let outlines = lines.joined(separator: "\n")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Nook Subscriptions</title>
          </head>
          <body>
        \(outlines)
          </body>
        </opml>
        """

        return Data(xml.utf8)
    }
}

public struct OPMLDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.opml, .xml] }
    public static var writableContentTypes: [UTType] { [.opml] }

    public var feeds: [Feed]

    public init(feeds: [Feed]) {
        self.feeds = feeds
    }

    public init(configuration: ReadConfiguration) throws {
        feeds = []
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: OPMLService().exportData(for: feeds))
    }
}

extension UTType {
    /// The `.opml` extension usually has no registered UTI, so macOS types the
    /// file as a dynamic type derived from the extension. Deriving our type the
    /// same way (no forced `conformingTo:`) makes those files selectable in the
    /// open panel; `.xml` still covers files typed as XML.
    public static var opml: UTType {
        UTType(filenameExtension: "opml") ?? .xml
    }
}

private final class OPMLOutlineParser: NSObject, XMLParserDelegate {
    private var parserError: Error?
    private var feeds: [OPMLFeed] = []
    private var seenFeedURLs: Set<String> = []
    private var folderStack: [String] = []
    private var outlineIsFolder: [Bool] = []

    func parse(data: Data) throws -> [OPMLFeed] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw parser.parserError ?? parserError ?? CocoaError(.fileReadCorruptFile)
        }

        return feeds
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        let rawFeedURL = (attributeDict["xmlUrl"] ?? attributeDict["xmlurl"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (attributeDict["title"] ?? attributeDict["text"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let rawFeedURL, !rawFeedURL.isEmpty, let feedURL = URL(string: rawFeedURL) {
            outlineIsFolder.append(false)
            guard seenFeedURLs.insert(feedURL.absoluteString).inserted else { return }
            let siteURL = (attributeDict["htmlUrl"] ?? attributeDict["htmlurl"]).flatMap(URL.init(string:))
            feeds.append(
                OPMLFeed(
                    title: title.isEmpty ? (feedURL.host ?? feedURL.absoluteString) : title,
                    feedURL: feedURL,
                    siteURL: siteURL,
                    category: folderStack.last
                )
            )
        } else {
            // A folder outline: remember its title as the category for children.
            outlineIsFolder.append(true)
            folderStack.append(title.isEmpty ? String(localized: "Ungrouped", bundle: Bundle.module) : title)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName.lowercased() == "outline", let wasFolder = outlineIsFolder.popLast() else { return }
        if wasFolder, !folderStack.isEmpty {
            folderStack.removeLast()
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parserError = parseError
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
