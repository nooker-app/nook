import NookKit
import SwiftUI
import UIKit

/// A share-extension "find the feed" request, routed via `nook://discover-feed`.
struct FeedDiscoveryRequest: Identifiable {
    let pageURLString: String
    var id: String { pageURLString }
}

/// Explores a shared page for its RSS/Atom feed WITHOUT subscribing. Found →
/// the feed's address with copy and follow actions; not found → an offer to
/// report the site so its feed rule can be added by hand.
struct FeedDiscoverySheet: View {
    @Bindable var store: ReaderStore
    let pageURLString: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Phase {
        case searching
        case found(ParsedFeed)
        case failed
    }

    @State private var phase: Phase = .searching
    @State private var isFollowing = false
    @State private var didFollow = false
    @State private var didCopy = false
    @State private var followError: String?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color("ListBackground").ignoresSafeArea())
                .navigationTitle("Find the Feed")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(Color("AccentColor"))
        .presentationDetents([.medium, .large])
        .task {
            // Discovery only — nothing is added until the user says so.
            do {
                let parsed = try await RSSFeedService().fetch(url: RSSFeedService().normalizedFeedURL(from: pageURLString))
                phase = .found(parsed)
            } catch {
                phase = .failed
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .searching:
            VStack(spacing: 14) {
                ProgressView()
                Text("Looking for this site's feed…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(verbatim: pageURLString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 32)
            }

        case .found(let parsed):
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                VStack(spacing: 6) {
                    Text("Found it!")
                        .font(.title3.bold())
                    Text(verbatim: parsed.feed.displayTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // The discovered feed address, in the open.
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(verbatim: parsed.feed.feedURL.absoluteString)
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 28)

                if let followError {
                    Text(verbatim: followError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 28)
                }

                VStack(spacing: 10) {
                    Button {
                        follow(parsed)
                    } label: {
                        if isFollowing {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                        } else {
                            Text(alreadyFollowing(parsed) || didFollow ? "Following ✓" : "Follow This Site")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFollowing || didFollow || alreadyFollowing(parsed))

                    Button {
                        UIPasteboard.general.string = parsed.feed.feedURL.absoluteString
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Feed Address", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 40)
            }
            .sensoryFeedback(.success, trigger: didFollow)

        case .failed:
            VStack(spacing: 18) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    Text("No feed found")
                        .font(.title3.bold())
                    Text("This site doesn't seem to share its posts anywhere Nook can find. You can report it — feed rules for popular sites are added by hand.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                VStack(spacing: 10) {
                    Button {
                        if let mail = reportMailURL { openURL(mail) }
                    } label: {
                        Label("Report This Site", systemImage: "envelope")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task {
                            do {
                                let id = try await store.saveLink(urlString: pageURLString)
                                _ = id
                                dismiss()
                            } catch {
                                followError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Save Page as Article Instead", systemImage: "bookmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 40)

                if let followError {
                    Text(verbatim: followError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 28)
                }
            }
        }
    }

    private func alreadyFollowing(_ parsed: ParsedFeed) -> Bool {
        store.feeds.contains {
            $0.feedURL.feedIdentityKey == parsed.feed.feedURL.feedIdentityKey
                || $0.siteURL.feedIdentityKey == parsed.feed.feedURL.feedIdentityKey
        }
    }

    private func follow(_ parsed: ParsedFeed) {
        guard !isFollowing else { return }
        isFollowing = true
        followError = nil
        Task {
            do {
                try await store.addFeed(urlString: parsed.feed.feedURL.absoluteString)
                didFollow = true
            } catch {
                followError = error.localizedDescription
            }
            isFollowing = false
        }
    }

    /// A pre-filled report to the developer with the page that had no feed.
    private var reportMailURL: URL? {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&?=+/:"))
        let subject = "Nook feed report".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let body = "No feed was found for this site:\n\(pageURLString)\n\nIf you know its feed address, paste it here:\n"
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "mailto:rationlunas@gmail.com?subject=\(subject)&body=\(body)")
    }
}
