import Foundation
import NookKit
import SwiftUI
import UIKit

/// State machine for one 읽기 맞춤 (Reading Fit) session. Owns the paragraph
/// queue, trial timing, online validity + silent requeueing, probes, the hard
/// time cap, and the final verdicts — the views only render its published
/// stage. Nothing is written to AppStorage until `apply()`.
@MainActor
@Observable
final class CalibrationSession {
    // MARK: - Stages

    enum Stage: Equatable {
        case intro
        case font
        /// A bridge overlay between chapters; `next` is entered on dismissal.
        case bridge(text: String)
        case trial
        case probe
        case analyzing
        case result
        /// The whole session was too noisy to trust — offer quick-pick.
        case unstable
        /// Preference-only tier (also the accessibility/VoiceOver route).
        case quickPick
    }

    private enum PhasePlan: Equatable {
        case warmup
        case size(step: Int)
        case spacing(step: Int)
    }

    // MARK: - Published state

    private(set) var stage: Stage = .intro
    /// 0…1 across the whole measured session; never regresses.
    private(set) var progress: Double = 0
    private(set) var currentParagraph: CalibrationParagraph?
    /// Typography the current trial paragraph must render with.
    private(set) var trialTypography = ReaderTypography.platformDefault
    private(set) var currentProbe: CalibrationProbe?
    private(set) var isWarmup = false
    private(set) var result: CalibrationResult?
    /// True when the corpus had to fall back to bundled samples.
    private(set) var usesBundledCorpus = false
    /// The font the user picked on S1 (defaults to their current setting).
    var chosenFont: ReaderFont

    // MARK: - Configuration and material

    private let currentSize: Int
    private let currentLineHeight: Double
    private let currentSpacing: Double
    private let script: CalibrationScript
    private var paragraphs: [CalibrationParagraph]
    private var usedParagraphIDs: Set<String> = []
    let sourceTitles: [String]

    // MARK: - Trial bookkeeping

    private var plan: [PhasePlan] = []
    private var planIndex = 0
    private var trials: [CalibrationTrial] = []
    private var replacements: [CalibrationPhase: Int] = [:]
    private var probesTaken: [CalibrationPhase: Int] = [:]
    private var probeAfterSteps: Set<Int> = []
    private var trialStart: Date?
    private var sessionStart = Date()
    private var totalSteps = 1
    private var completedSteps = 0
    private var fastRejections = 0
    private(set) var showPaceHint = false
    private var seed = UInt64.random(in: .min ... .max)
    private var lastTrialForProbe: CalibrationTrial?
    /// Size the spacing phase renders at: the provisional size verdict.
    private var provisionalSize: Int

    /// Hard cap — past this, remaining trials are skipped and whatever axes
    /// completed go to the result.
    private let hardCap: TimeInterval = 7 * 60

    // MARK: - Init

    init(store: ReaderStore, font: ReaderFont, size: Int, lineHeight: Double, spacing: Double) {
        chosenFont = font
        currentSize = size
        currentLineHeight = lineHeight
        currentSpacing = spacing
        provisionalSize = size

        // Gather eligible paragraphs from the user's real feeds: recent first,
        // unread preferred, at most two per article, ineligible prose dropped.
        let feedTitleByID = Dictionary(store.feeds.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        let candidates = store.libraryArticles
            .filter { $0.publishedAt > cutoff }
            .sorted { (!$0.isRead && $1.isRead) || (($0.isRead == $1.isRead) && $0.publishedAt > $1.publishedAt) }

        var korean: [CalibrationParagraph] = []
        var latin: [CalibrationParagraph] = []
        for article in candidates {
            var taken = 0
            for (index, paragraph) in article.bodyParagraphs.enumerated() {
                guard taken < 2 else { break }
                let script = CalibrationEngine.script(of: paragraph)
                guard CalibrationEngine.isEligible(paragraph, script: script) else { continue }
                let item = CalibrationParagraph(
                    id: "\(article.id)#\(index)",
                    text: paragraph,
                    sourceTitle: feedTitleByID[article.feedID] ?? article.title,
                    articleID: article.id
                )
                if script == .korean { korean.append(item) } else { latin.append(item) }
                taken += 1
            }
            if korean.count >= 24 || latin.count >= 24 { break }
        }

        // One session = one script: whichever the feeds supply more of.
        let needed = 18
        let resolvedScript: CalibrationScript
        let resolvedParagraphs: [CalibrationParagraph]
        let bundled: Bool
        if korean.count >= needed || latin.count >= needed {
            resolvedScript = korean.count >= latin.count ? .korean : .latin
            resolvedParagraphs = (resolvedScript == .korean ? korean : latin).shuffled()
            bundled = false
        } else {
            resolvedScript = Locale.current.language.languageCode?.identifier == "ko" ? .korean : .latin
            resolvedParagraphs = CalibrationCorpus.paragraphs(for: resolvedScript).shuffled()
            bundled = true
        }
        script = resolvedScript
        paragraphs = resolvedParagraphs
        usesBundledCorpus = bundled
        sourceTitles = Array(Set(resolvedParagraphs.map(\.sourceTitle))).sorted()
    }

    // MARK: - Flow control

    func begin() {
        stage = .font
    }

    func beginQuickPick() {
        stage = .quickPick
    }

    func confirmFont() {
        // Build the measured plan: warmup, 5 size trials, 6 spacing trials.
        let ladder = usesAccessibilityLadder ? CalibrationEngine.accessibilitySizeLadder : CalibrationEngine.sizeLadder
        plan = [.warmup]
        plan += CalibrationEngine.sizePresentationOrder.indices.map { .size(step: $0) }
        plan += (0..<6).map { .spacing(step: $0) }
        _ = ladder   // sizes resolved per-step below
        planIndex = 0
        totalSteps = plan.count
        completedSteps = 0
        sessionStart = Date()
        // One probe in each measured phase's middle, one near its end.
        probeAfterSteps = [3, 5, 8, 10]
        stage = .bridge(text: String(localized: "Now just read a few short pieces the way you always do.\nTap “Done reading” when you finish each one."))
    }

    func dismissBridge() {
        startNextTrial()
    }

    /// The user finished reading the current trial paragraph.
    func finishTrial() {
        guard let start = trialStart, let paragraph = currentParagraph else { return }
        let seconds = Date().timeIntervalSince(start)
        guard seconds >= 1.0 else { return }   // debounce double-taps

        let phase = currentPhase
        let condition = currentCondition
        let characters = CalibrationEngine.countableCharacters(in: paragraph.text)
        let cps = seconds > 0 ? Double(characters) / seconds : 0
        let plausible = CalibrationEngine.isPlausibleTrial(seconds: seconds, cps: cps, script: script)

        let trial = CalibrationTrial(
            phase: phase,
            position: positionInPhase,
            condition: condition,
            paragraphID: paragraph.id,
            countableCharacters: characters,
            seconds: seconds,
            isValid: plausible
        )

        if phase == .warmup {
            // Warmup absorbs practice; never analyzed, never requeued.
            advance(after: trial)
            return
        }

        if plausible {
            trials.append(trial)
            lastTrialForProbe = trial
            if probeAfterSteps.contains(planIndex), (probesTaken[phase] ?? 0) < 2,
               let probe = makeProbe(for: paragraph) {
                probesTaken[phase, default: 0] += 1
                currentProbe = probe
                stage = .probe
                CalibrationHaptic.light()
                return
            }
            advance(after: trial)
        } else {
            if seconds < 2.0 {
                fastRejections += 1
                if fastRejections == 3 { showPaceHint = true }
            }
            requeueCurrentCondition()
        }
    }

    enum ProbeAnswer { case present, absent, unsure }

    func answerProbe(_ answer: ProbeAnswer) {
        defer { currentProbe = nil }
        // A wrong answer on a suspiciously fast read invalidates that trial —
        // skimming, not reading. "Unsure" never penalizes.
        if let probe = currentProbe, let last = lastTrialForProbe, answer != .unsure {
            let saidPresent = answer == .present
            let wrong = saidPresent != probe.isPresent
            let phaseMedian = medianCPS(for: last.phase)
            if wrong, let phaseMedian, last.cps > phaseMedian, let index = trials.lastIndex(of: last) {
                trials[index].isValid = false
                requeueCurrentCondition()
                return
            }
        }
        advance(after: nil)
    }

    func dismissPaceHint() { showPaceHint = false }

    /// The app left the foreground mid-trial: that reading time is meaningless.
    func invalidateCurrentTrial() {
        guard stage == .trial else { return }
        trialStart = Date()   // restart timing with a fresh look at the text
    }

    /// User bailed early: produce a result from whatever axes completed.
    func finishEarly() {
        analyze()
    }

    var hasPartialResults: Bool {
        trials.contains { $0.phase == .size && $0.isValid }
    }

    // MARK: - Quick pick

    func applyQuickPick(font: ReaderFont, size: Int, lineHeight: Double) {
        snapshotCurrent()
        let defaults = UserDefaults.standard
        defaults.set(font.rawValue, forKey: "readerFont")
        defaults.set(size, forKey: "readerFontSize")
        defaults.set(lineHeight, forKey: "readerLineHeight")
        Self.storeLastRun(date: Date())
    }

    // MARK: - Result application

    func apply(lineHeight: Double) {
        guard let result else { return }
        snapshotCurrent()
        let defaults = UserDefaults.standard
        defaults.set(result.fontChoice.rawValue, forKey: "readerFont")
        if case .change(let size, _) = result.sizeOutcome {
            defaults.set(Int(size), forKey: "readerFontSize")
        }
        if case .change(let spacing, _) = result.spacingOutcome {
            defaults.set(spacing, forKey: "readerLetterSpacing")
        }
        defaults.set(lineHeight, forKey: "readerLineHeight")
        Self.storeLastRun(date: result.date)
    }

    private func snapshotCurrent() {
        let snapshot = CalibrationSnapshot(
            date: Date(),
            font: ReaderFont(rawValue: UserDefaults.standard.string(forKey: "readerFont") ?? "") ?? .system,
            fontSize: UserDefaults.standard.object(forKey: "readerFontSize") as? Int ?? 18,
            lineHeight: UserDefaults.standard.object(forKey: "readerLineHeight") as? Double ?? 1.7,
            letterSpacing: UserDefaults.standard.object(forKey: "readerLetterSpacing") as? Double ?? 0
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    // MARK: - Static bookkeeping (settings rows)

    static let snapshotKey = "calibration.previousTypography.v1"
    static let lastRunKey = "calibration.lastRun.v1"

    static func storeLastRun(date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastRunKey)
    }

    static var lastRunDate: Date? {
        let raw = UserDefaults.standard.double(forKey: lastRunKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    static var revertSnapshot: CalibrationSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(CalibrationSnapshot.self, from: data) else { return nil }
        // The revert offer expires after 30 days.
        guard Date().timeIntervalSince(snapshot.date) < 30 * 24 * 3600 else { return nil }
        return snapshot
    }

    static func revert() {
        guard let snapshot = revertSnapshot else { return }
        let defaults = UserDefaults.standard
        defaults.set(snapshot.font.rawValue, forKey: "readerFont")
        defaults.set(snapshot.fontSize, forKey: "readerFontSize")
        defaults.set(snapshot.lineHeight, forKey: "readerLineHeight")
        defaults.set(snapshot.letterSpacing, forKey: "readerLetterSpacing")
        defaults.removeObject(forKey: snapshotKey)
    }

    // MARK: - Internals

    var usesAccessibilityLadder: Bool {
        UITraitCollection.current.preferredContentSizeCategory.isAccessibilityCategory
    }

    private var currentPhase: CalibrationPhase {
        switch plan[planIndex] {
        case .warmup: .warmup
        case .size: .size
        case .spacing: .spacing
        }
    }

    private var positionInPhase: Int {
        switch plan[planIndex] {
        case .warmup: 0
        case .size(let step): step
        case .spacing(let step): step
        }
    }

    private var currentCondition: Double {
        switch plan[planIndex] {
        case .warmup:
            return Double(currentSize)
        case .size(let step):
            let ladder = usesAccessibilityLadder ? CalibrationEngine.accessibilitySizeLadder : CalibrationEngine.sizeLadder
            return Double(ladder[CalibrationEngine.sizePresentationOrder[step]])
        case .spacing(let step):
            return CalibrationEngine.spacingPresentationOrder(seed: seed)[step]
        }
    }

    private func typography(for planStep: PhasePlan) -> ReaderTypography {
        switch planStep {
        case .warmup:
            return ReaderTypography(
                font: chosenFont, fontSize: CGFloat(currentSize),
                lineHeightMultiple: 1.7, letterSpacingEM: 0
            )
        case .size:
            return ReaderTypography(
                font: chosenFont, fontSize: currentCondition,
                lineHeightMultiple: 1.7, letterSpacingEM: 0
            )
        case .spacing:
            return ReaderTypography(
                font: chosenFont, fontSize: CGFloat(provisionalSize),
                lineHeightMultiple: 1.7, letterSpacingEM: currentCondition
            )
        }
    }

    private func advance(after trial: CalibrationTrial?) {
        if let trial, trial.phase == .warmup { /* warmup recorded nowhere */ _ = trial }
        completedSteps += 1
        progress = max(progress, Double(completedSteps) / Double(totalSteps))
        CalibrationHaptic.light()

        // Hard cap: skip whatever remains and analyze what we have.
        if Date().timeIntervalSince(sessionStart) > hardCap {
            analyze()
            return
        }

        planIndex += 1
        guard planIndex < plan.count else {
            analyze()
            return
        }

        // Chapter boundary: entering the spacing phase resolves the
        // provisional size and shows the one mid-session bridge.
        if case .spacing(step: 0) = plan[planIndex] {
            resolveProvisionalSize()
            CalibrationHaptic.medium()
            stage = .bridge(text: String(localized: "Nice — past halfway. Next is the space between letters. Everyone's answer is different."))
            return
        }
        startNextTrial()
    }

    private func startNextTrial() {
        guard planIndex < plan.count else { return }
        guard let paragraph = nextParagraph() else {
            // Out of material: analyze what exists rather than stalling.
            analyze()
            return
        }
        currentParagraph = paragraph
        trialTypography = typography(for: plan[planIndex])
        isWarmup = currentPhase == .warmup
        trialStart = Date()
        stage = .trial
    }

    private func requeueCurrentCondition() {
        let phase = currentPhase
        let used = replacements[phase, default: 0]
        if used < 2, let paragraph = nextParagraph() {
            replacements[phase] = used + 1
            currentParagraph = paragraph
            trialStart = Date()
            stage = .trial
        } else {
            // Condition unrecoverable — move on; the verdict's minimum-data
            // gate will handle the gap honestly.
            advance(after: nil)
        }
    }

    private func nextParagraph() -> CalibrationParagraph? {
        guard let next = paragraphs.first(where: { !usedParagraphIDs.contains($0.id) }) else { return nil }
        usedParagraphIDs.insert(next.id)
        return next
    }

    private func makeProbe(for paragraph: CalibrationParagraph) -> CalibrationProbe? {
        seed &+= 1
        let wantPresent = (probesTaken[currentPhase] ?? 0) == 0
        let pool = paragraphs.filter { $0.id != paragraph.id }.prefix(4).map(\.text)
        return CalibrationEngine.probe(
            for: paragraph.text, negativePool: Array(pool), wantPresent: wantPresent, seed: seed
        )
    }

    private func medianCPS(for phase: CalibrationPhase) -> Double? {
        let values = trials.filter { $0.phase == phase && $0.isValid }.map(\.cps)
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func resolveProvisionalSize() {
        let ladder = usesAccessibilityLadder ? CalibrationEngine.accessibilitySizeLadder : CalibrationEngine.sizeLadder
        let outcome = CalibrationEngine.sizeVerdict(
            trials: trials,
            currentSize: currentSize,
            replacementsUsed: replacements[.size] ?? 0,
            ladder: ladder
        )
        if case .change(let size, _) = outcome {
            provisionalSize = Int(size)
        } else {
            provisionalSize = currentSize
        }
    }

    private func analyze() {
        stage = .analyzing
        let ladder = usesAccessibilityLadder ? CalibrationEngine.accessibilitySizeLadder : CalibrationEngine.sizeLadder
        let sizeOutcome = CalibrationEngine.sizeVerdict(
            trials: trials,
            currentSize: currentSize,
            replacementsUsed: replacements[.size] ?? 0,
            ladder: ladder
        )
        let spacingOutcome = CalibrationEngine.spacingVerdict(
            trials: trials,
            currentSpacing: currentSpacing
        )
        let sessionResult = CalibrationResult(
            date: Date(),
            script: script,
            fontChoice: chosenFont,
            sizeOutcome: sizeOutcome,
            spacingOutcome: spacingOutcome,
            sourceTitles: sourceTitles
        )
        result = sessionResult
        progress = 1

        // Both measured axes refused for instability → dedicated exit.
        let bothUnstable = sizeOutcome == .keep(reason: .unstable)
            && spacingOutcome == .keep(reason: .unstable)

        Task { @MainActor in
            // The analysis moment: the pause gives the result its weight.
            try? await Task.sleep(for: .seconds(1.8))
            CalibrationHaptic.success()
            stage = bothUnstable ? .unstable : .result
        }
    }

    // MARK: - Result presentation helpers

    var currentTypography: ReaderTypography {
        ReaderTypography(
            font: ReaderFont(rawValue: UserDefaults.standard.string(forKey: "readerFont") ?? "") ?? .system,
            fontSize: CGFloat(currentSize),
            lineHeightMultiple: currentLineHeight,
            letterSpacingEM: currentSpacing
        )
    }

    func recommendedTypography(lineHeight: Double) -> ReaderTypography {
        guard let result else { return currentTypography }
        var size = CGFloat(currentSize)
        if case .change(let value, _) = result.sizeOutcome { size = value }
        var spacing = currentSpacing
        if case .change(let value, _) = result.spacingOutcome { spacing = value }
        return ReaderTypography(
            font: result.fontChoice,
            fontSize: size,
            lineHeightMultiple: lineHeight,
            letterSpacingEM: spacing
        )
    }

    /// A paragraph not used in any trial, for the result preview card.
    var previewParagraph: CalibrationParagraph? {
        paragraphs.first { !usedParagraphIDs.contains($0.id) } ?? paragraphs.first
    }
}


/// Simple feedback for the calibration flow (the reader's CHHaptics engine is
/// tuned for its own gestures; these are the standard system taps).
@MainActor
enum CalibrationHaptic {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
