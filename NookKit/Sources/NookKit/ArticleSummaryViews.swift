import SwiftUI

public struct ArticleSummarySettingsContent: View {
    @AppStorage(ArticleSummarySettings.enabledKey) private var enabled = false
    @AppStorage(ArticleSummarySettings.automaticKey) private var automatic = false
    @AppStorage(ArticleSummarySettings.styleKey) private var style = ArticleSummaryStyle.concise.rawValue
    @AppStorage(TranslationSettings.summaryProviderKey) private var provider = TranslationProvider.appleIntelligence.rawValue

    public init() {}

    public var body: some View {
        Toggle("Enable AI summaries", isOn: $enabled)

        Picker("Summary style", selection: $style) {
            ForEach(ArticleSummaryStyle.allCases) { style in
                Text(style.label).tag(style.rawValue)
            }
        }
        .disabled(!enabled)

        Picker("AI provider", selection: $provider) {
            Text("Apple Intelligence", bundle: .module)
                .tag(TranslationProvider.appleIntelligence.rawValue)
            Text("Gemini", bundle: .module)
                .tag(TranslationProvider.gemini.rawValue)
        }
        .disabled(!enabled)

        Toggle("Summarize articles automatically", isOn: $automatic)
            .disabled(!enabled)

        if enabled,
           automatic,
           provider == TranslationProvider.gemini.rawValue {
            Label {
                Text("Automatic Gemini summaries can increase API usage and may incur charges. A request is made whenever an article is opened.", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }

        Text("Summaries use only the Markdown shown by the native reader and appear above the original article. They may be omitted when the content cannot be summarized reliably.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)

        if enabled, provider == TranslationProvider.gemini.rawValue {
            Text("Gemini sends article Markdown to Google and requires an API key in Translation Engine settings.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

public struct ArticleSummaryCard: View {
    public let summary: String
    public let style: ArticleSummaryStyle
    public let provider: TranslationProvider
    @State private var isExpanded = true

    public init(
        summary: String,
        style: ArticleSummaryStyle,
        provider: TranslationProvider
    ) {
        self.summary = summary
        self.style = style
        self.provider = provider
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: provider == .appleIntelligence ? "apple.intelligence" : "sparkles")
                        .foregroundStyle(.tint)
                    Text("AI Summary", bundle: .module)
                        .fontWeight(.semibold)
                    Text(style.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                Text(renderedSummary)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                Text("The original article remains below for comparison.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var renderedSummary: AttributedString {
        StreamingMarkdownFormatter.attributed(
            summary,
            baseSize: summaryBodySize,
            blockSeparator: "\n\n"
        )
    }

    private var summaryBodySize: CGFloat {
        #if os(macOS)
        15
        #else
        17
        #endif
    }
}

public struct ArticleSummaryActionButton: View {
    public let isLoading: Bool
    public let issue: ArticleSummaryIssue?
    public let action: () -> Void

    public init(
        isLoading: Bool,
        issue: ArticleSummaryIssue? = nil,
        action: @escaping () -> Void
    ) {
        self.isLoading = isLoading
        self.issue = issue
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue {
                Label {
                    Text(verbatim: message(for: issue))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: issue == .providerUnavailable
                        ? "exclamationmark.triangle"
                        : "info.circle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Button(action: action) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: issue == nil ? "apple.intelligence" : "arrow.clockwise")
                    }
                    buttonTitle
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
            .accessibilityLabel(buttonTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttonTitle: Text {
        if isLoading { return Text("Summarizing…", bundle: .module) }
        if issue != nil { return Text("Try Again", bundle: .module) }
        return Text("Summarize", bundle: .module)
    }

    private func message(for issue: ArticleSummaryIssue) -> String {
        switch issue {
        case .noReliableSummary:
            String(localized: "No reliable summary could be generated. The article may already be concise or may not contain enough readable content.", bundle: .module)
        case .providerUnavailable:
            String(localized: "The selected AI provider is unavailable. Check Apple Intelligence availability or the Gemini API key in Settings.", bundle: .module)
        }
    }
}
