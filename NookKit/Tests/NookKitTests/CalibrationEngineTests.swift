import Foundation
import Testing
@testable import NookKit

/// The calibration engine's contract: recommendations only when the math has
/// earned them, "keep" for every kind of doubt, and counterbalancing/detrending
/// that actually neutralizes practice and fatigue.
@Suite("Reading Fit engine")
struct CalibrationEngineTests {
    // MARK: - Fixtures

    /// Size-phase trials from a speed function, in the engine's own
    /// counterbalanced presentation order, 130 countable chars each.
    private func sizeTrials(speed: (Int) -> Double, invalidSizes: Set<Int> = []) -> [CalibrationTrial] {
        CalibrationEngine.sizePresentationOrder.enumerated().map { position, ladderIndex in
            let size = CalibrationEngine.sizeLadder[ladderIndex]
            let cps = speed(size)
            return CalibrationTrial(
                phase: .size,
                position: position,
                condition: Double(size),
                paragraphID: "p\(position)",
                countableCharacters: 130,
                seconds: 130 / cps,
                isValid: !invalidSizes.contains(size)
            )
        }
    }

    /// Spacing trials laid out exactly like the real presentation: each
    /// condition once per half, second half mirrored — so a condition's two
    /// trials sit at mirrored positions and linear trends cancel.
    private func spacingTrials(speeds: [Double: [Double]]) -> [CalibrationTrial] {
        let firstHalf = speeds.keys.sorted()
        let order = firstHalf + firstHalf.reversed()
        var seen: [Double: Int] = [:]
        return order.enumerated().map { position, condition in
            let index = seen[condition, default: 0]
            seen[condition] = index + 1
            let cps = speeds[condition]![index]
            return CalibrationTrial(
                phase: .spacing,
                position: position,
                condition: condition,
                paragraphID: "s\(position)",
                countableCharacters: 130,
                seconds: 130 / cps
            )
        }
    }

    // MARK: - Size: knee search

    @Test("A clear knee recommends knee × 1.3")
    func kneeFound() {
        // Plateau ~6 cps down to 17pt, collapse below.
        let outcome = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { $0 >= 17 ? 6.0 : 3.5 }),
            currentSize: 24,
            replacementsUsed: 0
        )
        // knee 17 → 17 × 1.3 = 22.1 → 22
        #expect(outcome == .change(to: 22, evidence: .strong))
    }

    @Test("A noisy dip cannot drag the knee below the monotonicity gate")
    func monotonicityGate() {
        // 14pt dips below 90% of plateau, 12pt "recovers" — noise. The knee
        // must stop at 17, not fall through to 12.
        let speeds: [Int: Double] = [24: 6.0, 20: 6.1, 17: 5.9, 14: 4.0, 12: 6.0]
        let outcome = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { speeds[$0]! }),
            currentSize: 17,
            replacementsUsed: 0
        )
        #expect(outcome == .change(to: 22, evidence: .strong))
    }

    @Test("No collapse anywhere keeps a comfortable current size")
    func noCollapseObserved() {
        let atSixteen = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { _ in 6.0 }),
            currentSize: 18,
            replacementsUsed: 0
        )
        #expect(atSixteen == .keep(reason: .alreadyFits))

        // …but a very small current size still gets the comfort floor.
        let atTwelve = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { _ in 6.0 }),
            currentSize: 12,
            replacementsUsed: 0
        )
        #expect(atTwelve == .change(to: 16, evidence: .strong))
    }

    @Test("A recommendation within 1pt of the current size is a keep")
    func nearMatchKeeps() {
        let outcome = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { $0 >= 17 ? 6.0 : 3.5 }),
            currentSize: 21,   // recommendation would be 22
            replacementsUsed: 0
        )
        #expect(outcome == .keep(reason: .alreadyFits))
    }

    @Test("Too few valid trials refuses to recommend")
    func insufficientSizeData() {
        let outcome = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { _ in 6.0 }, invalidSizes: [24, 17]),
            currentSize: 18,
            replacementsUsed: 2
        )
        #expect(outcome == .keep(reason: .insufficientData))
    }

    @Test("A collapsed second rung means no plateau reference — no verdict")
    func plateauIdentificationFailure() {
        let speeds: [Int: Double] = [24: 6.0, 20: 4.0, 17: 3.9, 14: 3.5, 12: 3.0]
        let outcome = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { speeds[$0]! }),
            currentSize: 18,
            replacementsUsed: 0
        )
        #expect(outcome == .keep(reason: .insufficientData))
    }

    @Test("Erratic plateau reads decline to recommend")
    func unstableSession() {
        let speeds: [Int: Double] = [24: 9.0, 20: 4.0, 17: 6.0, 14: 6.0, 12: 6.0]
        let outcome = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { speeds[$0]! }),
            currentSize: 18,
            replacementsUsed: 0
        )
        #expect(outcome == .keep(reason: .unstable))
    }

    @Test("Two paragraph replacements downgrade the evidence to weak")
    func replacementsWeakenEvidence() {
        let outcome = CalibrationEngine.sizeVerdict(
            trials: sizeTrials(speed: { $0 >= 17 ? 6.0 : 3.5 }),
            currentSize: 24,
            replacementsUsed: 2
        )
        #expect(outcome == .change(to: 22, evidence: .weak))
    }

    // MARK: - Spacing: dominance rule

    @Test("A dominating faster condition is adopted, never above weak evidence")
    func spacingDominanceAdopts() {
        let outcome = CalibrationEngine.spacingVerdict(
            trials: spacingTrials(speeds: [0: [5.0, 5.1], 0.03: [5.6, 5.7], 0.06: [5.0, 5.2]]),
            currentSpacing: 0
        )
        #expect(outcome == .change(to: 0.03, evidence: .weak))
    }

    @Test("Faster on average but not dominant is not enough")
    func spacingRequiresDominance() {
        // 0.03's mean is >5% up, but its second trial clearly loses to a
        // baseline trial — inconsistency, not a win.
        let outcome = CalibrationEngine.spacingVerdict(
            trials: spacingTrials(speeds: [0: [5.0, 5.6], 0.03: [5.8, 5.2], 0.06: [5.0, 5.1]]),
            currentSpacing: 0
        )
        #expect(outcome == .keep(reason: .noClearDifference))
    }

    @Test("Dominant but under the 5% margin is not enough")
    func spacingRequiresMargin() {
        let outcome = CalibrationEngine.spacingVerdict(
            trials: spacingTrials(speeds: [0: [5.0, 5.05], 0.03: [5.1, 5.15], 0.06: [5.0, 5.02]]),
            currentSpacing: 0
        )
        #expect(outcome == .keep(reason: .noClearDifference))
    }

    @Test("No evidence never silently zeroes a user's explicit spacing")
    func spacingPreservesExplicitSetting() {
        let outcome = CalibrationEngine.spacingVerdict(
            trials: spacingTrials(speeds: [0: [5.0, 5.2], 0.03: [5.1, 5.0], 0.06: [4.9, 5.1]]),
            currentSpacing: 0.05
        )
        #expect(outcome == .keep(reason: .noClearDifference))
    }

    @Test("The baseline dominating the user's spacing recommends returning to default")
    func spacingReverseProtection() {
        let outcome = CalibrationEngine.spacingVerdict(
            trials: spacingTrials(speeds: [0: [6.0, 6.1], 0.03: [5.6, 5.5], 0.06: [5.0, 5.2]]),
            currentSpacing: 0.04   // nearest tested condition: 0.03
        )
        #expect(outcome == .change(to: 0, evidence: .weak))
    }

    @Test("A missing baseline refuses to judge spacing at all")
    func spacingNeedsBaseline() {
        let outcome = CalibrationEngine.spacingVerdict(
            trials: spacingTrials(speeds: [0.03: [5.6, 5.7], 0.06: [5.0, 5.2]]),
            currentSpacing: 0
        )
        #expect(outcome == .keep(reason: .insufficientData))
    }

    // MARK: - Detrending and counterbalancing

    @Test("A realistic fatigue trend does not manufacture a size effect")
    func fatigueDoesNotManufactureCollapse() {
        // True speed identical at every size; fatigue slows each successive
        // trial by 4% (a realistic drift across five short paragraphs). The
        // counterbalanced order spreads that drift across the ladder, and the
        // 10% plateau tolerance absorbs what remains — verdict stays
        // "no collapse anywhere".
        let trials = CalibrationEngine.sizePresentationOrder.enumerated().map { position, ladderIndex -> CalibrationTrial in
            let size = CalibrationEngine.sizeLadder[ladderIndex]
            let cps = 6.0 * pow(0.96, Double(position))
            return CalibrationTrial(
                phase: .size, position: position, condition: Double(size),
                paragraphID: "p\(position)", countableCharacters: 130, seconds: 130 / cps
            )
        }
        let outcome = CalibrationEngine.sizeVerdict(trials: trials, currentSize: 18, replacementsUsed: 0)
        #expect(outcome == .keep(reason: .alreadyFits))
    }

    @Test("The spacing detrender recovers a condition effect under fatigue")
    func spacingDetrendRecoversEffect() {
        // True effect: +0.03em reads 10% faster. Fatigue drags every
        // successive trial down 5%. The mirrored-halves structure + detrend
        // must still surface the winner.
        let truth: [Double: Double] = [0: 5.0, 0.03: 5.5, 0.06: 5.0]
        let order: [Double] = [0, 0.03, 0.06, 0.06, 0.03, 0]
        let trials = order.enumerated().map { position, condition -> CalibrationTrial in
            let cps = truth[condition]! * pow(0.95, Double(position))
            return CalibrationTrial(
                phase: .spacing, position: position, condition: condition,
                paragraphID: "s\(position)", countableCharacters: 130, seconds: 130 / cps
            )
        }
        let outcome = CalibrationEngine.spacingVerdict(trials: trials, currentSpacing: 0)
        #expect(outcome == .change(to: 0.03, evidence: .weak))
    }

    @Test("The size presentation order decorrelates size from position")
    func presentationOrderIsCounterbalanced() {
        let order = CalibrationEngine.sizePresentationOrder
        #expect(order.sorted() == Array(0..<CalibrationEngine.sizeLadder.count))
        // Spearman-style check: correlation between ladder rank and position
        // must be near zero.
        let n = Double(order.count)
        let meanPos = (n - 1) / 2
        var covariance = 0.0, variancePos = 0.0, varianceRank = 0.0
        for (position, rank) in order.enumerated() {
            let dp = Double(position) - meanPos
            let dr = Double(rank) - meanPos
            covariance += dp * dr
            variancePos += dp * dp
            varianceRank += dr * dr
        }
        let correlation = covariance / (variancePos.squareRoot() * varianceRank.squareRoot())
        #expect(abs(correlation) < 0.35)
    }

    @Test("Spacing order shows every condition once per half, second half mirrored")
    func spacingOrderStructure() {
        let order = CalibrationEngine.spacingPresentationOrder(seed: 42)
        #expect(order.count == 6)
        let first = Array(order.prefix(3))
        let second = Array(order.suffix(3))
        #expect(Set(first) == Set(CalibrationEngine.spacingConditions))
        #expect(second == first.reversed())
    }

    // MARK: - Paragraph eligibility and probes

    @Test("The bundled corpus passes its own eligibility filter")
    func corpusIsEligible() {
        for paragraph in CalibrationCorpus.korean {
            #expect(CalibrationEngine.isEligible(paragraph, script: .korean), "KO out of band: \(paragraph.prefix(24))…")
            #expect(CalibrationEngine.script(of: paragraph) == .korean)
        }
        for paragraph in CalibrationCorpus.latin {
            #expect(CalibrationEngine.isEligible(paragraph, script: .latin), "EN out of band: \(paragraph.prefix(24))…")
            #expect(CalibrationEngine.script(of: paragraph) == .latin)
        }
    }

    @Test("URLs, markup, digits, and unterminated text are ineligible")
    func eligibilityRejectsNoise() {
        let base = String(repeating: "읽기와 산책은 서로 닮은 데가 많다고 느낀다. ", count: 6)
        #expect(CalibrationEngine.isEligible(base + "끝났다.", script: .korean))
        #expect(!CalibrationEngine.isEligible(base + "자세한 내용은 http://example.com 참고.", script: .korean))
        #expect(!CalibrationEngine.isEligible(base + "<em>강조</em>였다.", script: .korean))
        #expect(!CalibrationEngine.isEligible(base + "끝나지 않은 문장", script: .korean))
        #expect(!CalibrationEngine.isEligible("짧다.", script: .korean))
    }

    @Test("Probes pick real middle-content words and true negatives")
    func probeGeneration() throws {
        let paragraph = CalibrationCorpus.korean[0]
        let positive = try #require(CalibrationEngine.probe(
            for: paragraph, negativePool: [], wantPresent: true, seed: 7
        ))
        #expect(positive.isPresent)
        #expect(paragraph.contains(positive.word))

        let negative = try #require(CalibrationEngine.probe(
            for: paragraph, negativePool: [CalibrationCorpus.korean[1]], wantPresent: false, seed: 7
        ))
        #expect(!negative.isPresent)
        #expect(!paragraph.contains(negative.word))
    }

    @Test("Trial plausibility bounds by script")
    func plausibility() {
        #expect(CalibrationEngine.isPlausibleTrial(seconds: 20, cps: 6, script: .korean))
        #expect(!CalibrationEngine.isPlausibleTrial(seconds: 1.2, cps: 6, script: .korean))
        #expect(!CalibrationEngine.isPlausibleTrial(seconds: 4, cps: 32, script: .korean))
        #expect(CalibrationEngine.isPlausibleTrial(seconds: 4, cps: 32, script: .latin))
    }
}
