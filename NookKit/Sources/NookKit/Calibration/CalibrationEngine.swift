import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The decision core of 읽기 맞춤 (Reading Fit) — every function is pure, takes
/// value types, and is deterministic (callers pass the randomness), so the
/// whole recommendation logic is unit-testable without a pixel on screen.
///
/// Honesty is structural: each axis can answer "keep what you have" for four
/// distinct reasons, minimum-data gates precede every recommendation, and the
/// letter-spacing rule can never clear more than weak evidence — the UI only
/// repeats what the math actually knows.
public enum CalibrationEngine {
    // MARK: - Conditions and presentation orders

    /// Size ladder in points, largest first. The plateau is estimated from the
    /// top two rungs; the knee search walks down from there.
    public static let sizeLadder: [Int] = [24, 20, 17, 14, 12]
    /// Ladder shifted up for Dynamic Type accessibility users, whose critical
    /// print size is unlikely to sit inside the standard ladder at all.
    public static let accessibilitySizeLadder: [Int] = [28, 24, 20, 17, 14]

    /// Fixed pseudo-random presentation order (indices into the ladder):
    /// mid, top, bottom, upper-mid, lower-mid — size and presentation position
    /// correlate ≈ 0, so a practice or fatigue trend cannot masquerade as a
    /// size effect (the detrender removes what remains).
    public static let sizePresentationOrder: [Int] = [2, 0, 4, 1, 3]

    /// Letter-spacing conditions in em. Bidirectional by design: research says
    /// wider spacing helps crowding-sensitive readers and hurts fast readers.
    public static let spacingConditions: [Double] = [0, 0.03, 0.06]

    /// Six spacing trials: each condition once in the first half (shuffled by
    /// `seed`) and once in the second half in reverse order, so a linear
    /// fatigue trend cancels between halves.
    public static func spacingPresentationOrder(seed: UInt64) -> [Double] {
        var generator = SplitMix64(seed: seed)
        let firstHalf = spacingConditions.shuffled(using: &generator)
        return firstHalf + firstHalf.reversed()
    }

    // MARK: - Reading-speed primitives

    /// Characters that count toward reading speed: everything except
    /// whitespace and punctuation.
    public static func countableCharacters(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar),
               !CharacterSet.punctuationCharacters.contains(scalar),
               !CharacterSet.symbols.contains(scalar) {
                count += 1
            }
        }
    }

    /// Online validity: rules a trial can be checked against the moment it
    /// completes (the session silently requeues the condition on failure).
    public static func isPlausibleTrial(seconds: Double, cps: Double, script: CalibrationScript) -> Bool {
        seconds >= 2.0 && script.plausibleCPS.contains(cps)
    }

    /// Removes the linear practice/fatigue trend from a phase's trials: an OLS
    /// fit of log(cps) on presentation position, evaluated at the phase's mean
    /// position — so conditions are compared as if they had all been read at
    /// the same moment of the session.
    ///
    /// Only used for the spacing phase, where it is safe by construction: the
    /// mirrored-halves order gives every condition the same mean position, so
    /// a genuine condition effect cannot leak into the trend estimate. With
    /// fewer than 3 valid trials the trend is unidentifiable and the raw
    /// values are returned.
    public static func detrendedCPS(_ trials: [CalibrationTrial]) -> [Double] {
        let valid = trials.filter(\.isValid)
        guard valid.count >= 3 else { return trials.map(\.cps) }

        let xs = valid.map { Double($0.position) }
        let ys = valid.map { log(max($0.cps, 0.001)) }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        let slope: Double
        if denominator > 0 {
            let numerator = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
            slope = numerator / denominator
        } else {
            slope = 0
        }
        return trials.map { trial in
            exp(log(max(trial.cps, 0.001)) - slope * (Double(trial.position) - meanX))
        }
    }

    /// Coefficient of variation across the given values — the session-noise
    /// gate: above `unstableCV`, the axis declines to recommend anything.
    public static let unstableCV = 0.35

    public static func coefficientOfVariation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return sqrt(variance) / mean
    }

    // MARK: - Size verdict (knee search)

    /// Speed is expected to plateau above a personal critical print size and
    /// collapse below it (MNREAD). The knee is the smallest tested size that
    /// still reads at ≥90% of the plateau — with a monotonicity gate: every
    /// larger tested size must pass too, so one noisy dip cannot drag the knee
    /// downward. Recommendation = knee × 1.3, clamped to the settings range.
    public static func sizeVerdict(
        trials: [CalibrationTrial],
        currentSize: Int,
        replacementsUsed: Int,
        ladder: [Int] = sizeLadder
    ) -> CalibrationOutcome {
        // Raw cps, deliberately NOT detrended: with one trial per rung, a real
        // size effect leaks into the position regression, so detrending would
        // distort the very effect being measured. The counterbalanced
        // presentation order is the practice/fatigue defense here; what
        // remains lands inside the 10% plateau tolerance.
        let sized = trials.filter { $0.phase == .size }
        var speedBySize: [Int: Double] = [:]
        for trial in sized where trial.isValid {
            speedBySize[Int(trial.condition)] = trial.cps
        }

        // Minimum data: ≥4 of 5 trials valid, and at least one plateau rung.
        let plateauRungs = Array(ladder.prefix(2))
        let plateauSpeeds = plateauRungs.compactMap { speedBySize[$0] }
        guard speedBySize.count >= 4, !plateauSpeeds.isEmpty else {
            return .keep(reason: .insufficientData)
        }
        // Session-noise gate over the plateau rungs.
        if plateauSpeeds.count >= 2, coefficientOfVariation(plateauSpeeds) > unstableCV {
            return .keep(reason: .unstable)
        }
        let plateau = median(plateauSpeeds)

        // Plateau identification failure: the second rung already collapsed
        // relative to the first — there is no plateau to reference.
        if let top = speedBySize[ladder[0]], let second = speedBySize[ladder[1]],
           second < 0.9 * top {
            return .keep(reason: .insufficientData)
        }

        // Knee: smallest size where this rung AND every larger tested rung
        // hold ≥90% of the plateau.
        var knee = ladder[0]
        var allAboveHold = true
        for size in ladder {
            guard let speed = speedBySize[size] else { continue }
            if allAboveHold && speed >= 0.9 * plateau {
                knee = size
            } else {
                allAboveHold = false
            }
        }

        let evidence: CalibrationEvidence = replacementsUsed <= 1 ? .strong : .weak

        // No collapse observed anywhere on the ladder: the eyes handle even
        // the smallest rung. Recommend a comfortable floor, never an increase
        // the data didn't ask for.
        if knee == ladder.last {
            let floor = max(ladder.last! + 4, 16)
            if currentSize >= floor { return .keep(reason: .alreadyFits) }
            return .change(to: Double(floor), evidence: evidence)
        }

        let recommended = min(max(Int((1.3 * Double(knee)).rounded()), 14), 28)
        if abs(recommended - currentSize) <= 1 {
            return .keep(reason: .alreadyFits)
        }
        return .change(to: Double(recommended), evidence: evidence)
    }

    // MARK: - Spacing verdict (dominance rule)

    /// A spacing change must earn itself twice over: the candidate's two trials
    /// must BOTH beat both baseline trials (dominance), and its mean must lead
    /// by ≥5%. With n=2 per condition that is still thin, so the evidence chip
    /// never rises above `weak` — honesty is part of the spec.
    ///
    /// The rule is bidirectional: it can also recommend returning to 0 em when
    /// the baseline dominates the user's current explicit spacing. What it
    /// never does is silently zero a user's setting without evidence.
    public static func spacingVerdict(
        trials: [CalibrationTrial],
        currentSpacing: Double
    ) -> CalibrationOutcome {
        let spaced = trials.filter { $0.phase == .spacing }
        let adjusted = detrendedCPS(spaced)
        var speedsByCondition: [Double: [Double]] = [:]
        for (trial, value) in zip(spaced, adjusted) where trial.isValid {
            speedsByCondition[trial.condition, default: []].append(value)
        }

        guard let baseline = speedsByCondition[0], !baseline.isEmpty else {
            return .keep(reason: .insufficientData)
        }
        if baseline.count >= 2, coefficientOfVariation(baseline) > unstableCV {
            return .keep(reason: .unstable)
        }
        let baselineMean = baseline.reduce(0, +) / Double(baseline.count)

        // Forward: does a wider condition dominate the baseline?
        var winner: (condition: Double, mean: Double)?
        for condition in spacingConditions.dropFirst() {
            guard let speeds = speedsByCondition[condition], speeds.count >= 2 else { continue }
            let dominates = speeds.allSatisfy { candidate in
                baseline.allSatisfy { candidate > $0 }
            }
            let mean = speeds.reduce(0, +) / Double(speeds.count)
            if dominates, mean >= 1.05 * baselineMean {
                if winner == nil || mean > winner!.mean {
                    winner = (condition, mean)
                }
            }
        }
        if let winner {
            if abs(winner.condition - currentSpacing) < 0.005 {
                return .keep(reason: .alreadyFits)
            }
            return .change(to: winner.condition, evidence: .weak)
        }

        // Reverse protection: the user has explicit spacing, and the baseline
        // dominates the condition nearest their setting.
        if currentSpacing > 0.005 {
            let nearest = spacingConditions.dropFirst().min {
                abs($0 - currentSpacing) < abs($1 - currentSpacing)
            }
            if let nearest,
               let nearSpeeds = speedsByCondition[nearest], nearSpeeds.count >= 2,
               baseline.count >= 2 {
                let nearMean = nearSpeeds.reduce(0, +) / Double(nearSpeeds.count)
                let baselineDominates = baseline.allSatisfy { base in
                    nearSpeeds.allSatisfy { base > $0 }
                }
                if baselineDominates, baselineMean >= 1.05 * nearMean {
                    return .change(to: 0, evidence: .weak)
                }
            }
        }

        return .keep(reason: .noClearDifference)
    }

    // MARK: - Fitting a passage to the device

    /// Fraction of the measured viewport a passage may occupy. The margin
    /// absorbs the difference between this estimate and SwiftUI's own line
    /// breaking. The estimate errs high by design (measured at 15–20% over
    /// SwiftUI's layout): over-estimating only costs a slightly shorter
    /// passage, while under-estimating would clip one — the exact failure this
    /// fitting exists to prevent.
    static let fitSafetyFactor: CGFloat = 0.92

    /// Reading load bounds, in countable characters. The floor keeps a trial
    /// long enough that the constant tap overhead stays a negligible share of
    /// the measured time (≈8 seconds of reading); the ceiling keeps the whole
    /// session inside its time budget.
    /// The floor is what keeps a trial long enough that the constant tap
    /// overhead stays a negligible share of the measured time (≈8 seconds of
    /// reading). The ceiling sits just above the corpus's longest passage, so a
    /// device with room trims nothing at all — the engine tests pin both ends
    /// against the corpus itself.
    static func readingLoadBounds(for script: CalibrationScript) -> ClosedRange<Int> {
        switch script {
        case .latin: 110...300
        case .korean: 45...125
        case .japanese: 50...132
        case .chineseSimplified: 38...100
        }
    }

    /// Renders a structured passage with the reader's own typography: the same
    /// font factory, the same heading scale, the same kern. Built as one
    /// attributed string — heading and paragraphs in a single text run — so the
    /// height measured here is exactly the height that gets drawn, which is what
    /// lets a passage be fitted instead of clipped.
    ///
    /// Line spacing lives *inside* the paragraph style rather than on a SwiftUI
    /// modifier, so measurement and rendering read the same value. Paragraph
    /// gaps are real short blank lines rather than `paragraphSpacing`: SwiftUI's
    /// `Text` ignores `paragraphSpacing` while `boundingRect` counts it, so
    /// using it would render no gap *and* over-predict the height (verified
    /// against SwiftUI's own layout).
    public static func attributed(
        _ passage: CalibrationPassage,
        typography: ReaderTypography
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = typography.lineSpacing
        style.lineBreakMode = .byWordWrapping
        style.alignment = .natural

        func attributes(size: CGFloat, bold: Bool) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: HTMLContentText.finalBodyFont(
                    baseSize: size, bold: bold, italic: false, design: typography.design
                ),
                .paragraphStyle: style,
            ]
            if typography.kern != 0 { attributes[.kern] = typography.kern }
            return attributes
        }

        /// A blank line whose height is the reader's paragraph gap.
        func gap() -> NSAttributedString {
            NSAttributedString(
                string: "\n",
                attributes: attributes(size: HTMLTextFlow.paragraphGap(for: typography.bodySize), bold: false)
            )
        }

        if !passage.heading.isEmpty {
            output.append(NSAttributedString(
                string: passage.heading + "\n",
                attributes: attributes(size: typography.headingSize(3), bold: true)
            ))
        }

        for (index, paragraph) in passage.paragraphs.enumerated() {
            if index > 0 || !passage.heading.isEmpty { output.append(gap()) }
            for (text, bold) in emphasisRuns(paragraph) {
                output.append(NSAttributedString(
                    string: text, attributes: attributes(size: typography.bodySize, bold: bold)
                ))
            }
            if index < passage.paragraphs.count - 1 {
                output.append(NSAttributedString(
                    string: "\n", attributes: attributes(size: typography.bodySize, bold: false)
                ))
            }
        }
        return output
    }

    /// SwiftUI-ready form of `attributed`.
    public static func attributedString(
        _ passage: CalibrationPassage,
        typography: ReaderTypography
    ) -> AttributedString {
        let rendered = attributed(passage, typography: typography)
        #if canImport(AppKit)
        return (try? AttributedString(rendered, including: \.appKit)) ?? AttributedString(passage.plainText)
        #else
        return (try? AttributedString(rendered, including: \.uiKit)) ?? AttributedString(passage.plainText)
        #endif
    }

    /// Splits `**emphasis**` markers into runs. Unbalanced markers degrade to
    /// plain text rather than swallowing the passage.
    static func emphasisRuns(_ text: String) -> [(String, Bool)] {
        let pieces = text.components(separatedBy: "**")
        guard pieces.count > 1, pieces.count.isMultiple(of: 2) == false else {
            return [(text.replacingOccurrences(of: "**", with: ""), false)]
        }
        return pieces.enumerated().compactMap { index, piece in
            piece.isEmpty ? nil : (piece, !index.isMultiple(of: 2))
        }
    }

    /// Rendered height of a structured passage at this typography and width.
    public static func measuredHeight(
        _ passage: CalibrationPassage,
        typography: ReaderTypography,
        width: CGFloat
    ) -> CGFloat {
        guard width > 0 else { return 0 }
        return attributed(passage, typography: typography).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        ).height.rounded(.up)
    }

    /// Countable characters across the whole passage, heading included — the
    /// reader's eyes pass over all of it, so all of it counts toward speed.
    public static func countableCharacters(in passage: CalibrationPassage) -> Int {
        countableCharacters(in: passage.plainText)
    }

    /// The character load one session uses for **every** trial, whatever the
    /// condition: the capacity of the tightest rung (the largest type size) on
    /// this device, clamped to the reading-load bounds.
    ///
    /// Sizing every trial the same way is what keeps the comparison clean. If
    /// each trial instead filled the viewport, the small-type rungs would show
    /// several times more text than the large ones — different durations, so a
    /// different share of per-trial tap overhead in each condition, biasing the
    /// very plateau the knee search depends on.
    public static func sessionCharacterTarget(
        script: CalibrationScript,
        largestSize: CGFloat,
        design: ReaderFont,
        width: CGFloat,
        height: CGFloat
    ) -> Int {
        let bounds = readingLoadBounds(for: script)
        guard width > 0, height > 0 else { return bounds.upperBound }
        let typography = ReaderTypography(
            font: design, fontSize: largestSize, lineHeightMultiple: 1.7, letterSpacingEM: 0
        )
        let budget = height * fitSafetyFactor
        // Gauge against the corpus's TALLEST passage at the tightest rung: if
        // the worst case fits, no passage in the session needs trimming, which
        // is what keeps every trial's reading load identical. A real passage is
        // used (not a flat sample) because the heading and the paragraph break
        // take vertical space of their own.
        let corpus = CalibrationCorpus.passages(for: script)
        guard let sample = corpus.max(by: {
            measuredHeight($0, typography: typography, width: width)
                < measuredHeight($1, typography: typography, width: width)
        }) else {
            return bounds.upperBound
        }
        let full = corpus.map { countableCharacters(in: $0) }.max() ?? bounds.upperBound
        if measuredHeight(sample, typography: typography, width: width) <= budget {
            return min(max(full, bounds.lowerBound), bounds.upperBound)
        }
        // Too tall at the tightest rung: find the longest trimmed form that fits.
        var low = bounds.lowerBound
        var high = full
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = trimmed(sample, toCountableCharacters: mid)
            if measuredHeight(candidate, typography: typography, width: width) <= budget {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return min(max(low, bounds.lowerBound), bounds.upperBound)
    }

    /// Fits one standardized passage to this trial: normally the passage as
    /// written, and when the device cannot show all of it at this type size, the
    /// same passage with trailing sentences dropped — heading and paragraph
    /// break kept, ending on a complete sentence.
    ///
    /// Trimming to `targetCharacters`, a session-wide value derived from the
    /// tightest rung, keeps every trial the same length, which is the property
    /// the matched corpus exists to provide. Nothing is ever left to scroll:
    /// scrolling would fold motor time into the reading measurement, and a
    /// clipped paragraph is what makes text stop registering.
    public static func fittedPassage(
        _ passage: CalibrationPassage,
        typography: ReaderTypography,
        width: CGFloat,
        height: CGFloat,
        targetCharacters: Int
    ) -> CalibrationPassage? {
        guard !passage.paragraphs.isEmpty else { return nil }
        // No viewport reported yet (a preview before layout): show it as written.
        guard width > 1, height > 1 else { return passage }

        let budget = height * fitSafetyFactor
        if countableCharacters(in: passage) <= targetCharacters,
           measuredHeight(passage, typography: typography, width: width) <= budget {
            return passage
        }

        // Drop whole trailing sentences until it fits both bounds. The heading
        // and the paragraph break survive — the structure is what makes the
        // passage readable, so it is the last thing to go.
        var candidate = trimmed(passage, toCountableCharacters: targetCharacters)
        while measuredHeight(candidate, typography: typography, width: width) > budget {
            let shorter = trimmed(candidate, toCountableCharacters: countableCharacters(in: candidate) - 1)
            guard shorter != candidate, !shorter.paragraphs.isEmpty else { return nil }
            candidate = shorter
        }
        return candidate.paragraphs.isEmpty ? nil : candidate
    }

    /// The passage with trailing sentences removed until it holds at most
    /// `limit` countable characters. Never cuts inside a sentence, and drops an
    /// emptied paragraph rather than leaving a stub.
    static func trimmed(_ passage: CalibrationPassage, toCountableCharacters limit: Int) -> CalibrationPassage {
        var paragraphs = passage.paragraphs
        func total() -> Int {
            countableCharacters(in: CalibrationPassage(heading: passage.heading, paragraphs: paragraphs))
        }
        while total() > limit, !paragraphs.isEmpty {
            var sentences = splitSentences(paragraphs[paragraphs.count - 1])
            if sentences.count <= 1 {
                // A single-sentence paragraph goes whole rather than becoming a
                // fragment — unless it is the only paragraph left.
                if paragraphs.count == 1 { break }
                paragraphs.removeLast()
            } else {
                sentences.removeLast()
                paragraphs[paragraphs.count - 1] = sentences.joined(separator: " ")
            }
        }
        return CalibrationPassage(id: passage.id, heading: passage.heading, paragraphs: paragraphs)
    }

    /// Splits on sentence terminators, keeping the terminator attached — so a
    /// trimmed excerpt always ends on a complete sentence.
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        for character in text {
            current.append(character)
            if terminators.contains(character) {
                let candidate = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { sentences.append(candidate) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    
    // MARK: - Probes

    /// Builds a "was this word in it?" probe. Positive probes pick a content
    /// word from the middle of the paragraph (Korean: a 2–4 syllable token,
    /// Latin: 4+ letters); negative probes pick a plausible word from another
    /// paragraph that does NOT appear in the read one. No feedback is shown —
    /// probes only guard against skimming, they are not a quiz.
    public static func probe(
        for paragraph: String,
        script: CalibrationScript,
        negativePool: [String],
        wantPresent: Bool,
        seed: UInt64
    ) -> CalibrationProbe? {
        var generator = SplitMix64(seed: seed)

        if wantPresent {
            let words = contentWords(in: paragraph, script: script)
            let middle = words.dropFirst(words.count / 4).dropLast(words.count / 4)
            guard let word = Array(middle).randomElement(using: &generator) ?? words.randomElement(using: &generator) else { return nil }
            return CalibrationProbe(word: word, isPresent: true)
        } else {
            let candidates = negativePool
                .flatMap { contentWords(in: $0, script: script) }
                .filter { !paragraph.contains($0) }
            guard let word = candidates.randomElement(using: &generator) else { return nil }
            return CalibrationProbe(word: word, isPresent: false)
        }
    }

    static func contentWords(in text: String, script: CalibrationScript) -> [String] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        switch script {
        case .latin:
            return tokens.map(String.init).filter { token in
                token.count >= 4 && token.allSatisfy(\.isLetter)
            }
        case .korean:
            return tokens.map(String.init).filter { token in
                let syllables = token.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
                return syllables >= 2 && syllables <= 4 && syllables == token.count
            }
        case .japanese, .chineseSimplified:
            // Unsegmented scripts: probe on 2–3 character runs of Han/Kana,
            // which read as words without needing a tokenizer.
            var words: [String] = []
            for token in tokens {
                let scalars = Array(String(token).unicodeScalars)
                guard scalars.count >= 2 else { continue }
                var index = 0
                while index + 2 <= scalars.count {
                    let slice = scalars[index..<min(index + 2, scalars.count)]
                    if slice.allSatisfy(isHanOrKana) {
                        words.append(String(String.UnicodeScalarView(slice)))
                    }
                    index += 2
                }
            }
            return words
        }
    }

    private static func isHanOrKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)      // CJK unified ideographs
            || (0x3040...0x309F).contains(scalar.value)   // Hiragana
            || (0x30A0...0x30FF).contains(scalar.value)   // Katakana
    }

    // MARK: - Helpers

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Small deterministic RNG so presentation orders and probes are reproducible
/// in tests while still varying per session (the session passes a fresh seed).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
