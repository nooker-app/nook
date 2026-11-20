#if os(macOS)
import SwiftUI

private struct MagazinePreviewVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var magazinePreviewVisible: Bool {
        get { self[MagazinePreviewVisibleKey.self] }
        set { self[MagazinePreviewVisibleKey.self] = newValue }
    }
}

public extension View {
    /// A lazy grid's onAppear includes prefetched rows. Actual viewport
    /// visibility owns the request instead, including cancellation on exit.
    func magazinePreviewDemand(active: Bool, paused: Bool = false) -> some View {
        modifier(MagazinePreviewDemand(active: active, paused: paused))
    }
}

private struct MagazinePreviewDemand: ViewModifier {
    var active: Bool
    var paused: Bool
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            // Headline glyph layout deliberately disables animation to keep
            // ellipses stable. Move the entire card as one geometry group when a
            // preceding card grows, or its title jumps ahead of the other rows.
            .geometryGroup()
            .opacity(visible || paused ? 1 : 0)
            .offset(y: reduceMotion || visible || paused ? 0 : 16)
            .environment(\.magazinePreviewVisible, visible && active)
            // One viewport subscription drives both the reveal and preview
            // demand. A separate animated observer doubled the graph updates.
            .onScrollVisibilityChange(threshold: 0.01) { next in
                guard next != visible else { return }
                if next && !paused {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.34)) { visible = true }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { visible = next }
                }
            }
            .onDisappear { visible = false }
    }
}

/// Keeps the text card intact until pixels are decoded. The image reveals from
/// the top while its reserved height grows, so the title never rewraps or scales.
public struct MagazineArticleThumbnail: View {
    let article: Article
    let height: CGFloat
    let expanded: Bool
    let lead: Bool
    @State private var image: CGImage?
    @State private var revealed = false
    @Environment(\.magazinePreviewVisible) private var visible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let preferences = ArticlePreviewPreferences.shared

    public init(article: Article, height: CGFloat, expanded: Bool = false, lead: Bool = false) {
        self.article = article
        self.height = height
        self.expanded = expanded
        self.lead = lead
    }

    private var taskID: String {
        "\(article.id)|\(article.url)|\(visible)|\(expanded)|\(scenePhase == .active)|\(preferences.revision)"
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: height)
                    .clipped()
                    .opacity(revealed ? 1 : 0)
            }
        }
        .frame(height: revealed ? height : 0, alignment: .top)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .task(id: taskID) {
            guard visible || expanded else { return }
            if image == nil, let cached = await ArticlePreviewCache.shared.cachedThumbnail(for: article) {
                guard !Task.isCancelled else { return }
                show(cached, animated: false)
            }
            guard visible, !expanded, scenePhase == .active, preferences.policy(for: article.feedID).enabled else { return }
            do {
                // Ignore cards crossed during a fast flick, and let the lead start
                // first without prefetching the entire loaded page of articles.
                try await Task.sleep(for: .milliseconds(lead ? 180 : 420))
                await ReaderStore.shared.seedMagazinePreview(for: article)
                try Task.checkCancellation()
                if image == nil,
                   let supplied = try await ArticlePreviewCache.shared.prepareFeedThumbnail(article, policy: preferences.policy(for: article.feedID)) {
                    try Task.checkCancellation()
                    show(supplied, animated: true)
                }
                let result = try await ArticlePreviewCache.shared.prepare(article, policy: preferences.policy(for: article.feedID))
                try Task.checkCancellation()
                if let result, image == nil { show(result, animated: true) }
            } catch { /* A failed preview leaves a complete, usable text card. */ }
        }
    }

    private func show(_ result: CGImage, animated: Bool) {
        #if DEBUG
        MainThreadLog.add("magazine.thumbnail.show", ms: 0)
        if animated { MainThreadLog.add("magazine.thumbnail.reveal", ms: 0) }
        MainThreadLog.note("magazine.thumbnail", extra: "animated=\(animated ? 1 : 0)")
        #endif
        image = result
        withAnimation(animated && !reduceMotion ? .spring(duration: 0.48, bounce: 0) : nil) {
            revealed = true
        }
    }
}
#endif
