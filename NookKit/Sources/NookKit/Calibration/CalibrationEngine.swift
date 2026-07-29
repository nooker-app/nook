import Foundation

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

    // MARK: - Paragraph eligibility

    /// Whether a feed paragraph qualifies as test material: prose-like, a
    /// single paragraph, free of URLs/markup/number-heavy content, sentence-
    /// terminated, and inside the script's length band.
    public static func isEligible(_ text: String, script: CalibrationScript) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
        let lowered = trimmed.lowercased()
        if lowered.contains("http") || lowered.contains("www.") { return false }
        if trimmed.contains("<") || trimmed.contains("&#") { return false }

        let countable = countableCharacters(in: trimmed)
        guard script.paragraphLengthBand.contains(countable) else { return false }

        // Number/symbol-heavy text (tables, scores, code) reads at a different
        // cadence than prose and would contaminate the comparison.
        let noisy = trimmed.unicodeScalars.filter {
            CharacterSet.decimalDigits.contains($0) || CharacterSet.symbols.contains($0)
        }.count
        guard Double(noisy) < 0.15 * Double(max(countable, 1)) else { return false }

        guard let last = trimmed.unicodeScalars.last else { return false }
        let terminators = CharacterSet(charactersIn: ".!?…。？！”\"’)")
        return terminators.contains(last)
    }

    /// The script a paragraph belongs to, by Hangul share — deterministic, so
    /// tests don't depend on NaturalLanguage model versions.
    public static func script(of text: String) -> CalibrationScript {
        var hangul = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            if (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value) {
                hangul += 1
                letters += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
        }
        guard letters > 0 else { return .latin }
        return Double(hangul) / Double(letters) > 0.3 ? .korean : .latin
    }

    // MARK: - Probes

    /// Builds a "was this word in it?" probe. Positive probes pick a content
    /// word from the middle of the paragraph (Korean: a 2–4 syllable token,
    /// Latin: 4+ letters); negative probes pick a plausible word from another
    /// paragraph that does NOT appear in the read one. No feedback is shown —
    /// probes only guard against skimming, they are not a quiz.
    public static func probe(
        for paragraph: String,
        negativePool: [String],
        wantPresent: Bool,
        seed: UInt64
    ) -> CalibrationProbe? {
        var generator = SplitMix64(seed: seed)
        let script = script(of: paragraph)

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
        case .korean:
            return tokens.map(String.init).filter { token in
                let syllables = token.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
                return syllables >= 2 && syllables <= 4 && syllables == token.count
            }
        case .latin:
            return tokens.map(String.init).filter { token in
                token.count >= 4 && token.allSatisfy(\.isLetter)
            }
        }
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
