import NookKit
import SwiftUI

/// S6 — the result of a Reading Fit session. The signature moment is the
/// preview card: the same paragraph morphing between the current and the
/// recommended typography under a segmented toggle, so the difference can be
/// replayed with a fingertip. Verdict rows say exactly what the math knows —
/// evidence chips, honest "kept as is" reasons, and no invented percentages.
struct CalibrationResultView: View {
    @Bindable var session: CalibrationSession
    let initialLineHeight: Double
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsRecommended = true
    @State private var lineHeight: Double = 1.7
    @State private var appearedOnce = false

    private var result: CalibrationResult? { session.result }

    private var recommended: ReaderTypography { session.recommendedTypography(lineHeight: lineHeight) }
    private var current: ReaderTypography { session.currentTypography }
    private var anythingChanges: Bool {
        guard let result else { return false }
        if case .change = result.sizeOutcome { return true }
        if case .change = result.spacingOutcome { return true }
        return result.fontChoice != current.design
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(anythingChanges ? String(localized: "This looks like your fit") : String(localized: "Your current settings already fit"))
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                previewCard

                if let result {
                    VStack(spacing: 10) {
                        verdictRow(
                            title: String(localized: "Font Size"),
                            outcome: result.sizeOutcome,
                            currentText: "\(Int(current.bodySize))pt",
                            format: { "\(Int($0))pt" }
                        )
                        verdictRow(
                            title: String(localized: "Letter Spacing"),
                            outcome: result.spacingOutcome,
                            currentText: spacingLabel(currentSpacingEM),
                            format: { spacingLabel($0) }
                        )
                        fontRow(result)
                    }
                }

                Text("A recommendation based on how fast you read — a starting point, not a verdict. Read with it for a few days, re-fit any time, or adjust it directly in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                VStack(spacing: 10) {
                    if anythingChanges {
                        Button {
                            session.apply(lineHeight: lineHeight)
                            dismiss()
                        } label: {
                            Text("Use recommended settings")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if anythingChanges {
                        Button(String(localized: "Keep current settings")) { dismiss() }
                            .buttonStyle(.bordered)
                    } else {
                        Button {
                            dismiss()
                        } label: {
                            Text("Keep current settings")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            guard !appearedOnce else { return }
            appearedOnce = true
            lineHeight = [1.5, 1.7, 1.9].min {
                abs($0 - initialLineHeight) < abs($1 - initialLineHeight)
            } ?? 1.7
        }
    }

    // MARK: - Preview card

    @ViewBuilder
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if anythingChanges {
                Picker(String(localized: "Preview"), selection: $showsRecommended) {
                    Text("Current").tag(false)
                    Text("Recommended").tag(true)
                }
                .pickerStyle(.segmented)
            }

            let typography = showsRecommended ? recommended : current
            if let passage = session.previewPassage(for: typography) {
                Text(CalibrationEngine.attributedString(passage, typography: typography))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: showsRecommended)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: lineHeight)
            }

            Picker(String(localized: "Line Spacing"), selection: $lineHeight) {
                Text("Compact").tag(1.5)
                Text("Default").tag(1.7)
                Text("Roomy").tag(1.9)
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Verdict rows

    private var currentSpacingEM: Double {
        UserDefaults.standard.object(forKey: "readerLetterSpacing") as? Double ?? 0
    }

    private func spacingLabel(_ em: Double) -> String {
        em == 0 ? String(localized: "Default") : String(format: "%+.2fem", em)
    }

    @ViewBuilder
    private func verdictRow(
        title: String,
        outcome: CalibrationOutcome,
        currentText: String,
        format: (Double) -> String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(explanation(outcome))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                switch outcome {
                case .change(let value, let evidence):
                    Text(verbatim: "\(currentText) → \(format(value))")
                        .font(.subheadline.weight(.semibold))
                    chip(for: evidence)
                case .keep:
                    Text(currentText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func fontRow(_ result: CalibrationResult) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Font").font(.subheadline.weight(.medium))
                Text("The typeface you chose yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(result.fontChoice.label)
                    .font(.subheadline.weight(.semibold))
                Text("Preference")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func chip(for evidence: CalibrationEvidence) -> some View {
        switch evidence {
        case .strong:
            Text("Solid evidence")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.accentColor)
        case .weak:
            Text("Light evidence — take as a hint")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(.secondary)
        case .preference:
            Text("Preference")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    private func explanation(_ outcome: CalibrationOutcome) -> String {
        switch outcome {
        case .change(_, _):
            return String(localized: "You read noticeably faster this way.")
        case .keep(let reason):
            switch reason {
            case .alreadyFits:
                return String(localized: "Measured — what you have already fits.")
            case .noClearDifference:
                return String(localized: "No clear difference — keeping your setting.")
            case .insufficientData:
                return String(localized: "Not enough data — holding off on this one.")
            case .unstable:
                return String(localized: "Reading speed was uneven — holding off on this one.")
            }
        }
    }
}
