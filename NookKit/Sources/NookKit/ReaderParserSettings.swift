import SwiftUI

/// The rows for choosing which parser turns an article page into reader content.
/// Shared by both apps; each embeds it in its own Section (iOS `List`, macOS
/// `Form`). Localized via `.module`.
public struct ReaderParserSettingsContent: View {
    // The raw value rather than the enum, matching `TranslationEngineSettingsContent`
    // and — more importantly — `ReaderParserEngine.preferred`, which reads the same
    // key out of `UserDefaults` for the non-view code that does the extracting.
    // Storing an enum here and a string there is a setting that appears to reset.
    @AppStorage(ReaderParserEngine.storageKey)
    private var engine = ReaderParserEngine.fallback.rawValue
    /// The master switch for the built-in reader, which lives on the Experimental
    /// screen. With it off no parser runs there, and this setting reaches only the
    /// in-app browser's reader mode — worth saying rather than leaving a control that
    /// looks like it does more than it does.
    @AppStorage(ReaderStore.readerContentByDefaultKey)
    private var readerContentByDefault = true

    public init() {}

    private var selected: ReaderParserEngine {
        ReaderParserEngine(rawValue: engine) ?? .fallback
    }

    public var body: some View {
        Picker(selection: $engine) {
            ForEach(ReaderParserEngine.allCases) { engine in
                Text(engine.label).tag(engine.rawValue)
            }
        } label: {
            Text("Article Parser", bundle: .module)
        }

        Text(selected.summary)
            .font(.caption)
            .foregroundStyle(.secondary)

        // Said plainly because the alternative surprises people: the reader does not
        // re-fetch every article you have already opened when you change this. It
        // cannot — the extracted bodies are synced between your devices, and a
        // device on each parser would spend its life invalidating the other's work.
        Text("This applies to articles Nook reads from now on. An article you have already opened — here or on another device — keeps the parser that read it; use the parser menu in the reader to re-read one.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)

        if !readerContentByDefault {
            Text("Reader view is off, so this currently applies to reader mode in the in-app browser and to articles you download for offline reading.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
