import NookKit
import SwiftUI

/// 읽기 맞춤 (Reading Fit): a ~5-minute session that measures how the user
/// actually reads — on their own feed's paragraphs — and recommends typography.
/// The machinery (timers, trial counts, statistics) never shows; the user just
/// reads and taps. See `CalibrationSession` for the state machine and
/// `CalibrationEngine` for the decision math.
struct CalibrationView: View {
    @Bindable var store: ReaderStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0

    @State private var session: CalibrationSession?
    @State private var confirmingExit = false

    var body: some View {
        ZStack {
            Color("ListBackground").ignoresSafeArea()
            if let session {
                content(session)
            }
        }
        .onAppear {
            if session == nil {
                session = CalibrationSession(
                    store: store,
                    font: readerFont,
                    size: readerFontSize,
                    lineHeight: readerLineHeight,
                    spacing: readerLetterSpacing
                )
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session?.invalidateCurrentTrial() }
        }
    }

    @ViewBuilder
    private func content(_ session: CalibrationSession) -> some View {
        VStack(spacing: 0) {
            header(session)
            switch session.stage {
            case .intro:
                IntroStage(session: session, dismiss: { dismiss() })
            case .font:
                FontStage(session: session)
            case .bridge(let text):
                BridgeStage(text: text) { session.dismissBridge() }
            case .trial:
                TrialStage(session: session, reduceMotion: reduceMotion)
            case .probe:
                ProbeStage(session: session)
            case .analyzing:
                AnalyzingStage()
            case .result:
                CalibrationResultView(
                    session: session,
                    initialLineHeight: readerLineHeight,
                    dismiss: { dismiss() }
                )
            case .unstable:
                UnstableStage(session: session, dismiss: { dismiss() })
            case .quickPick:
                QuickPickStage(session: session, dismiss: { dismiss() })
            }
        }
        .confirmationDialog(
            Text("Stop here?"),
            isPresented: $confirmingExit,
            titleVisibility: .visible
        ) {
            if session.hasPartialResults {
                Button(String(localized: "Get my recommendation and finish")) { session.finishEarly() }
            }
            Button(String(localized: "Leave without saving"), role: .destructive) { dismiss() }
            Button(String(localized: "Keep going"), role: .cancel) {}
        } message: {
            Text("What you've read so far can already shape a recommendation.")
        }
        .alert(
            Text("Read at your own pace"),
            isPresented: Binding(
                get: { session.showPaceHint },
                set: { if !$0 { session.dismissPaceHint() } }
            )
        ) {
            Button(String(localized: "OK")) { session.dismissPaceHint() }
        } message: {
            Text("This isn't a timed quiz — just read comfortably.")
        }
    }

    @ViewBuilder
    private func header(_ session: CalibrationSession) -> some View {
        HStack {
            Button {
                if isMidSession(session) {
                    confirmingExit = true
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Close"))
            Spacer()
        }
        .overlay {
            // The single, never-regressing progress capsule — the only piece
            // of session machinery the user ever sees.
            if showsProgress(session) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 132, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 132 * session.progress, height: 3)
                            .animation(.smooth(duration: 0.35), value: session.progress)
                    }
            }
        }
        .padding(.horizontal, 8)
    }

    private func isMidSession(_ session: CalibrationSession) -> Bool {
        switch session.stage {
        case .trial, .probe, .bridge: true
        default: false
        }
    }

    private func showsProgress(_ session: CalibrationSession) -> Bool {
        switch session.stage {
        case .trial, .probe, .bridge, .analyzing: true
        default: false
        }
    }
}

// MARK: - S0 Intro

private struct IntroStage: View {
    let session: CalibrationSession
    let dismiss: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "textformat.size")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text("Reading Fit")
                .font(.title.weight(.semibold))
            Text("Read a few pieces from your own feeds the way you always do, and Nook will find the type size and spacing that suit your eyes — based on how you actually read.\nAbout five minutes, and quitting early still keeps what it learned.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if session.usesBundledCorpus {
                Text("Your library is still small, so Nook will use its own reading samples.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if voiceOverEnabled {
                Text("This measurement times visual reading, so with VoiceOver Nook offers direct choice instead.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Text("Nook measures quietly while you read. Results stay on this device.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            VStack(spacing: 10) {
                if voiceOverEnabled {
                    Button { session.beginQuickPick() } label: { primaryLabel(String(localized: "Choose directly")) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { session.begin() } label: { primaryLabel(String(localized: "Start")) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "Quick pick (about a minute)")) { session.beginQuickPick() }
                        .buttonStyle(.bordered)
                }
                Button(String(localized: "Maybe later")) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity).padding(.vertical, 6)
    }
}

// MARK: - S1 Font choice

private struct FontStage: View {
    @Bindable var session: CalibrationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("First, the typeface")
                .font(.title2.weight(.semibold))
            Text("A typeface is half taste. Pick whichever feels easy on your eyes.")
                .foregroundStyle(.secondary)

            if let paragraph = session.previewParagraph {
                ScrollView {
                    Text(paragraph.text)
                        .font(.system(size: 18, design: session.chosenFont.fontDesign))
                        .lineSpacing(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.smooth(duration: 0.2), value: session.chosenFont)
                }
                .frame(maxHeight: .infinity)
            }

            HStack(spacing: 10) {
                ForEach(ReaderFont.allCases) { font in
                    Button {
                        session.chosenFont = font
                    } label: {
                        VStack(spacing: 6) {
                            Text(verbatim: "Ag")
                                .font(.system(size: 28, design: font.fontDesign))
                            Text(font.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(session.chosenFont == font ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(session.chosenFont == font ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                session.confirmFont()
            } label: {
                Text("Continue with this typeface")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

// MARK: - Bridge

private struct BridgeStage: View {
    let text: String
    let proceed: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(text)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                proceed()
            } label: {
                Text("Okay")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .transition(.opacity)
    }
}

// MARK: - Trial

private struct TrialStage: View {
    let session: CalibrationSession
    let reduceMotion: Bool
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.isWarmup {
                Text("Warm-up — read the way you usually do")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let paragraph = session.currentParagraph {
                Text(verbatim: "〈\(paragraph.sourceTitle)〉")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                ScrollView {
                    // The measured surface: plain Text with the trial's exact
                    // typography — the same styling the reader itself uses.
                    Text(paragraph.text)
                        .font(.system(size: session.trialTypography.bodySize, design: session.trialTypography.fontDesign))
                        .kerning(session.trialTypography.kern)
                        .lineSpacing(session.trialTypography.lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(paragraph.id)
                        .transition(reduceMotion ? .identity : .opacity)
                }
                .frame(maxHeight: .infinity)
            }
            Button {
                session.finishTrial()
            } label: {
                Text("Done reading")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: session.currentParagraph?.id)
    }
}

// MARK: - Probe

private struct ProbeStage: View {
    let session: CalibrationSession

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Was this word in what you just read?")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
            if let probe = session.currentProbe {
                // System font on purpose: the probe must not leak the trial's
                // typography condition.
                Text(probe.word)
                    .font(.title.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer()
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button { session.answerProbe(.present) } label: {
                        Text("It was").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    Button { session.answerProbe(.absent) } label: {
                        Text("It wasn't").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
                Button(String(localized: "Can't remember")) { session.answerProbe(.unsure) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

// MARK: - Analyzing

private struct AnalyzingStage: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text("Making sense of your reading…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Unstable exit

private struct UnstableStage: View {
    let session: CalibrationSession
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.path")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("This session was a little bumpy")
                .font(.title2.weight(.semibold))
            Text("Your reading speed varied too much to make a confident recommendation. Try again somewhere quiet — or just pick what looks right, right now.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 10) {
                Button { session.beginQuickPick() } label: {
                    Text("Choose directly").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Button(String(localized: "Try again another time")) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

// MARK: - Quick pick (preference tier)

private struct QuickPickStage: View {
    let session: CalibrationSession
    let dismiss: () -> Void

    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7

    @State private var font: ReaderFont = .system
    @State private var size = 18
    @State private var lineHeight = 1.7
    @State private var appearedOnce = false

    private var preview: ReaderTypography {
        ReaderTypography(
            font: font, fontSize: CGFloat(size),
            lineHeightMultiple: lineHeight, letterSpacingEM: 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick what reads best")
                .font(.title2.weight(.semibold))

            if let paragraph = session.previewParagraph {
                ScrollView {
                    Text(paragraph.text)
                        .font(.system(size: preview.bodySize, design: preview.fontDesign))
                        .lineSpacing(preview.lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.smooth(duration: 0.2), value: preview)
                }
                .frame(maxHeight: .infinity)
            }

            Picker(String(localized: "Font"), selection: $font) {
                ForEach(ReaderFont.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Font Size: \(size)")
                Spacer()
                Stepper("", value: $size, in: 12...28).labelsHidden()
            }
            Picker(String(localized: "Line Spacing"), selection: $lineHeight) {
                Text("Compact").tag(1.5)
                Text("Default").tag(1.7)
                Text("Roomy").tag(1.9)
            }
            .pickerStyle(.segmented)

            Text("Your own choice — a precise measurement takes about 5 minutes.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                session.applyQuickPick(font: font, size: size, lineHeight: lineHeight)
                dismiss()
            } label: {
                Text("Use these settings")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .onAppear {
            guard !appearedOnce else { return }
            appearedOnce = true
            font = readerFont
            size = readerFontSize
            lineHeight = [1.5, 1.7, 1.9].min {
                abs($0 - readerLineHeight) < abs($1 - readerLineHeight)
            } ?? 1.7
        }
    }
}
