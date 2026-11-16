#if os(macOS)
import SwiftUI

/// The same byline appears on a magazine card and its expanded reader header.
public struct MagazineAuthorLine: View {
    private let authors: [String]
    private let expanded: Bool

    public init(authors: [String], expanded: Bool = false) {
        self.authors = authors
        self.expanded = expanded
    }

    public var body: some View {
        if !authors.isEmpty {
            let names = authors.joined(separator: ", ")
            Label {
                Text(names)
            } icon: {
                Image(systemName: "person.crop.circle").foregroundStyle(NookTheme.accent)
            }
            .font(.system(size: expanded ? 13 : 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(expanded ? 2 : 1)
            .help(names)
            .accessibilityLabel(Text("By \(names)", bundle: .module))
        }
    }
}
#endif
