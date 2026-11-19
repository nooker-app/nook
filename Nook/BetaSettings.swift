import AppKit
import NookKit
import SwiftUI

struct LayoutSettingsView: View {
    @AppStorage(MacLayoutPreference.layoutKey) private var layout = MacLayoutMode.classic.rawValue

    var body: some View {
        if layout == MacLayoutMode.magazine.rawValue {
            BetaSettingsView()
        } else {
            ReaderSettingsView()
        }
    }
}

/// Beta owns the navigation and section containers. The controls share their
/// bindings and actions with Classic, so switching layouts never forks settings.
struct BetaSettingsView: View {
    @State private var pane: Pane = .general
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    enum Pane: String, CaseIterable, Identifiable {
        case general, appearance, reading, feeds, organize, offline, publishing, intelligence, about
        var id: Self { self }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .appearance: String(localized: "Appearance")
            case .reading: String(localized: "Reading")
            case .feeds: String(localized: "Feeds")
            case .organize: String(localized: "Organize")
            case .offline: String(localized: "Offline")
            case .publishing: String(localized: "Publishing")
            case .intelligence: String(localized: "Intelligence & experiments")
            case .about: String(localized: "About")
            }
        }

        var subtitle: String {
            switch self {
            case .general: String(localized: "Make Nook feel at home.")
            case .appearance: String(localized: "A reading surface that feels like yours.")
            case .reading: String(localized: "Choose how each story opens and reads.")
            case .feeds: String(localized: "Keep your publications fresh and in sync.")
            case .organize: String(localized: "Give every story a place.")
            case .offline: String(localized: "Keep your reading close, wherever you are.")
            case .publishing: String(localized: "Your voice, your publication.")
            case .intelligence: String(localized: "Choose the intelligence behind your reading.")
            case .about: String(localized: "A quiet place for reading and writing.")
            }
        }

        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .appearance: "textformat.size"
            case .reading: "book.closed"
            case .feeds: "dot.radiowaves.up.forward"
            case .organize: "square.stack.3d.up"
            case .offline: "arrow.down.circle"
            case .publishing: "square.and.pencil"
            case .intelligence: "sparkles"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            navigation
                .frame(width: 220)
                .padding(16)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: pane.icon)
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.045)), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 7) {
                        MagazineHeadline(pane.title, size: 28)
                        Text(pane.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 24)

                detail
                    .id(pane)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 700, idealHeight: 780, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [NookTheme.canvas, NookTheme.accent.opacity(0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .containerBackground(NookTheme.canvas, for: .window)
        // The title belongs to the native toolbar, not to content underneath it.
        // Declarative toolbar preferences keep its layout valid across window
        // activation and layout switches without racing NSWindow setters.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 12) {
                    Text("Nook").font(.system(size: 21, weight: .semibold, design: .serif))
                    Rectangle().fill(NookTheme.hairline).frame(width: 1, height: 16)
                    Text("Settings").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Label("Changes save automatically", systemImage: "checkmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: pane)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("BETA").foregroundStyle(NookTheme.accent).font(.system(size: 8, weight: .bold)).tracking(1)
                    .padding(5).background(.primary.opacity(0.06), in: Capsule())
            }.padding(.horizontal, 10).padding(.vertical, 16)

            ForEach(Pane.allCases) { item in
                Button { pane = item } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.icon).frame(width: 20)
                        Text(item.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: pane == item ? .semibold : .medium))
                    .foregroundStyle(pane == item ? NookTheme.accent : .secondary)
                    .padding(.horizontal, 14).frame(height: 42)
                    .background {
                        if pane == item {
                            RoundedRectangle(cornerRadius: 12).fill(NookTheme.accent.opacity(0.12))
                                .glassEffect(.regular.tint(NookTheme.accent.opacity(0.045)), in: RoundedRectangle(cornerRadius: 12))
                                .matchedGeometryEffect(id: "pane", in: selection)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(MagazinePlainButtonStyle())
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(pane == item ? .isSelected : [])
            }
            Spacer()
            Image(systemName: "leaf")
                .font(.system(size: 24, weight: .ultraLight)).foregroundStyle(NookTheme.accent.opacity(0.5))
                .frame(maxWidth: .infinity).padding(18)
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.045)), in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: BetaSettingsForm { GeneralSettingsSections() }
        case .appearance: BetaSettingsForm { ReaderSettingsSections() }
        case .reading: BetaSettingsForm { MagazineRecommendationSettings(); ReadingSettingsSections() }
        case .feeds: BetaSettingsForm { MagazinePreviewSettings(feeds: ReaderStore.shared.feeds); FeedsSettingsSections() }
        case .organize: BetaSettingsForm { ArticleRulesSettingsSections(); FiltersSettingsSections() }
        case .offline: BetaSettingsForm { OfflineSettingsSections() }
        case .publishing: PlusSettingsScreenContent { rows in BetaSettingsForm { rows } }
        case .intelligence:
            BetaSettingsForm {
                MagazineTrendSettings()
                ExperimentalSettingsSections(magazine: true)
            }
        case .about:
            AboutSettingsPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular.tint(NookTheme.accent.opacity(0.045)), in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 28).padding(.bottom, 28)
        }
    }
}

private struct MagazineRecommendationSettings: View {
    @AppStorage(MagazineRecommendationController.enabledKey) private var enabled = true
    @State private var confirmingReset = false

    var body: some View {
        Section("Your magazine") {
            Toggle("Personalize recommendations", isOn: $enabled)
            Text("Nook ranks every unread story on this Mac using your choices, reading time, stars, and Not interested feedback. Your interests stay on this device. Marking a feed as read does not train recommendations.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset reading interests…") { confirmingReset = true }
                .confirmationDialog("Reset reading interests?", isPresented: $confirmingReset) {
                    Button("Reset reading interests", role: .destructive) { MagazineRecommendationController.reset() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This resets recommendation interests and excluded recommendations. Recently Read, your articles, and stars stay unchanged; starred stories still help guide recommendations.")
                }
        }
    }
}

private struct BetaSettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if !section.header.isEmpty {
                            HStack { section.header }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary).padding(.horizontal, 5)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(section.content) { row in
                                row.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .font(.system(size: 13))
                        .toggleStyle(MagazineSwitchStyle())
                        .controlSize(.regular)
                        .buttonStyle(MagazineGlassButtonStyle())
                        .menuStyle(.button)
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NookTheme.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.045)), in: RoundedRectangle(cornerRadius: 20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20).strokeBorder(NookTheme.hairline.opacity(0.5), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                        if !section.footer.isEmpty {
                            VStack(alignment: .leading, spacing: 4) { section.footer }
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 32).padding(.top, 2)
        }
        // Section subview proxies resolve environment where content is declared,
        // not where each extracted row is placed in the glass card.
        .toggleStyle(MagazineSwitchStyle())
        .buttonStyle(MagazineGlassButtonStyle())
        .menuStyle(.button)
        .controlSize(.regular)
        .labeledContentStyle(BetaSettingsLabelStyle())
    }
}

private struct BetaSettingsLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

private struct MagazineTrendSettings: View {
    @AppStorage("magazineTrendsEnabled") private var enabled = true
    var body: some View {
        Section("Magazine trends") {
            Toggle("Show short trends from recent articles", isOn: $enabled)
            Text("Apple Intelligence is used first. If unavailable, your configured AI provider can generate short trends from article titles. Otherwise, Nook shows a simple reading message.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
