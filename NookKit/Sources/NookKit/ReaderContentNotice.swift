import SwiftUI

/// Shown in the native reader while reader-mode content is being extracted from
/// the article page. Keeps the surface from flashing the RSS body first.
public struct ReaderLoadingPlaceholder: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading reader view…", bundle: .module)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }
}

/// Shown above the saved copy when the reader could not extract the original.
///
/// Two situations, deliberately not one notice. A page that answered 404 or 410
/// is gone, and deleting the article is the sensible thing to offer. A page that
/// loaded but yielded no body is still there, and offering deletion for it sent
/// people to delete perfectly good articles — most often short ones, where the
/// only thing wrong was that the extractor wanted more text than the post had.
public struct ReaderUnavailableNotice: View {
    /// Why the original could not be shown.
    public enum Reason: Sendable {
        /// The page answered 404 or 410. Nothing will bring it back.
        case gone
        /// The page loaded, but no article body came out of it.
        case notExtracted
    }

    private let reason: Reason
    private let onRetry: () -> Void
    private let onOpenOriginal: (() -> Void)?
    private let onDelete: () -> Void

    public init(
        reason: Reason,
        onRetry: @escaping () -> Void,
        onOpenOriginal: (() -> Void)? = nil,
        onDelete: @escaping () -> Void
    ) {
        self.reason = reason
        self.onRetry = onRetry
        self.onOpenOriginal = onOpenOriginal
        self.onDelete = onDelete
    }

    private var title: Text {
        switch reason {
        case .gone:
            Text("This article is no longer online", bundle: .module)
        case .notExtracted:
            Text("Couldn't read the original here", bundle: .module)
        }
    }

    private var detail: Text {
        switch reason {
        case .gone:
            Text("The page has been taken down. The saved copy is shown below, and you can delete the article if you no longer want it.", bundle: .module)
        case .notExtracted:
            Text("The page is still there, but no article text came out of it. The saved copy is shown below.", bundle: .module)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: reason == .gone ? "trash.slash" : "doc.text.magnifyingglass")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(.subheadline.weight(.semibold))
                    detail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button(action: onRetry) {
                    Text("Try Again", bundle: .module)
                }
                .buttonStyle(.bordered)

                if let onOpenOriginal, reason == .notExtracted {
                    Button(action: onOpenOriginal) {
                        Text("Open Original", bundle: .module)
                    }
                    .buttonStyle(.bordered)
                }

                // Offered only when the page really is gone. Deletion is not a
                // remedy for an extractor that came up empty.
                if reason == .gone {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Article", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
