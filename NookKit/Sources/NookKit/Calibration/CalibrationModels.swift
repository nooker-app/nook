import Foundation

/// The script a calibration session runs in. One session = one script: mixing
/// Korean and Latin paragraphs across conditions would confound every
/// comparison, and 모아쓰기 text may respond to spacing differently than Latin.
public enum CalibrationScript: String, Codable, Sendable {
    case korean
    case latin

    /// Plausible characters-per-second bounds for silent reading; anything
    /// outside is a mis-tap or a distraction, not a measurement.
    public var plausibleCPS: ClosedRange<Double> {
        switch self {
        case .korean: 1.5...20
        case .latin: 4...50
        }
    }

    /// Length band for test paragraphs, in countable (non-space) characters —
    /// roughly 15–35 seconds of natural reading.
    public var paragraphLengthBand: ClosedRange<Int> {
        switch self {
        case .korean: 80...160
        case .latin: 180...320
        }
    }
}

/// One test paragraph, tagged with where it came from so the result screen can
/// credit the source (and so a session never leans on one article).
public struct CalibrationParagraph: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var sourceTitle: String
    public var articleID: String?

    public init(id: String, text: String, sourceTitle: String, articleID: String? = nil) {
        self.id = id
        self.text = text
        self.sourceTitle = sourceTitle
        self.articleID = articleID
    }
}

/// Which axis a trial measured.
public enum CalibrationPhase: String, Codable, Sendable {
    case warmup
    case size
    case spacing
}

/// One completed reading trial.
public struct CalibrationTrial: Codable, Equatable, Sendable {
    public var phase: CalibrationPhase
    /// Presentation position within its phase (0-based) — the detrender's x.
    public var position: Int
    /// The condition value: font size in points (size phase) or letter
    /// spacing in em (spacing phase).
    public var condition: Double
    public var paragraphID: String
    public var countableCharacters: Int
    public var seconds: Double
    /// False when an online validity rule rejected it (too fast, implausible,
    /// interrupted, or a failed probe on a suspiciously fast read).
    public var isValid: Bool

    public init(
        phase: CalibrationPhase,
        position: Int,
        condition: Double,
        paragraphID: String,
        countableCharacters: Int,
        seconds: Double,
        isValid: Bool = true
    ) {
        self.phase = phase
        self.position = position
        self.condition = condition
        self.paragraphID = paragraphID
        self.countableCharacters = countableCharacters
        self.seconds = seconds
        self.isValid = isValid
    }

    public var cps: Double {
        seconds > 0 ? Double(countableCharacters) / seconds : 0
    }
}

/// How much the evidence behind a recommendation is worth — always surfaced
/// honestly in the result UI.
public enum CalibrationEvidence: String, Codable, Sendable {
    /// Clean data, clear effect.
    case strong
    /// Real signal but thin data (letter spacing is always at most this).
    case weak
    /// The user simply chose it (font, line height, quick-pick).
    case preference
}

/// The verdict for one axis. `keep` is a first-class outcome: when the data
/// doesn't justify a change, nothing is written and the UI says so.
public enum CalibrationOutcome: Equatable, Codable, Sendable {
    case change(to: Double, evidence: CalibrationEvidence)
    case keep(reason: KeepReason)

    public enum KeepReason: String, Codable, Sendable {
        /// Measured, and the current value is already right.
        case alreadyFits
        /// Measured, and no condition earned a change.
        case noClearDifference
        /// Not enough valid data to say anything.
        case insufficientData
        /// Reading speed was too erratic this session.
        case unstable
    }
}

/// A comprehension probe: "was this word in what you just read?" Words are
/// shown in the system font so the probe never leaks the trial's condition.
public struct CalibrationProbe: Equatable, Sendable {
    public var word: String
    /// Whether the word actually appeared in the probed paragraph.
    public var isPresent: Bool

    public init(word: String, isPresent: Bool) {
        self.word = word
        self.isPresent = isPresent
    }
}

/// Everything the result screen needs, plus the applied-snapshot bookkeeping.
public struct CalibrationResult: Codable, Equatable, Sendable {
    public var version: Int
    public var date: Date
    public var script: CalibrationScript
    public var fontChoice: ReaderFont
    public var sizeOutcome: CalibrationOutcome
    public var spacingOutcome: CalibrationOutcome
    /// Titles of the articles whose paragraphs were read, for attribution.
    public var sourceTitles: [String]

    public init(
        version: Int = 1,
        date: Date,
        script: CalibrationScript,
        fontChoice: ReaderFont,
        sizeOutcome: CalibrationOutcome,
        spacingOutcome: CalibrationOutcome,
        sourceTitles: [String]
    ) {
        self.version = version
        self.date = date
        self.script = script
        self.fontChoice = fontChoice
        self.sizeOutcome = sizeOutcome
        self.spacingOutcome = spacingOutcome
        self.sourceTitles = sourceTitles
    }
}

/// The typography snapshot taken before applying a calibration, so one tap
/// restores exactly what the user had.
public struct CalibrationSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var date: Date
    public var font: ReaderFont
    public var fontSize: Int
    public var lineHeight: Double
    public var letterSpacing: Double

    public init(date: Date, font: ReaderFont, fontSize: Int, lineHeight: Double, letterSpacing: Double) {
        version = 1
        self.date = date
        self.font = font
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
    }
}
