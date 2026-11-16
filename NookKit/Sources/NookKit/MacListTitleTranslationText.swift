#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// Text snapshots go straight to AppKit. Only a change in measured height
/// invalidates the SwiftUI layout containing the native label.
struct MacListTitleTranslationText: NSViewRepresentable {
    let title: String
    let box: ListTitleTranslator.StateBox
    let translator: ListTitleTranslator

    func makeNSView(context: Context) -> ListTitleNativeTextView {
        ListTitleNativeTextView()
    }

    func updateNSView(_ nsView: ListTitleNativeTextView, context: Context) {
        nsView.bind(title: title, box: box, translator: translator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ListTitleNativeTextView, context: Context) -> CGSize? {
        nsView.measuredSize(width: proposal.width)
    }

    static func dismantleNSView(_ nsView: ListTitleNativeTextView, coordinator: ()) {
        nsView.unbind()
    }
}

@MainActor
final class ListTitleNativeTextView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var box: ListTitleTranslator.StateBox?
    private var translator: ListTitleTranslator?
    private var title = ""
    private var generation = 0
    private var sizes: [CGFloat: CGSize] = [:]
    private var lastWidth: CGFloat?
    private var renderedText: String?
    private var renderedPlaceholder = false
    #if DEBUG
    private(set) var bindingUpdates = 0
    #endif

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        label.autoresizingMask = [.width, .height]
        label.frame = bounds
        addSubview(label)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The native table owns row selection and contextual actions.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func bind(title: String, box: ListTitleTranslator.StateBox, translator: ListTitleTranslator) {
        #if DEBUG
        bindingUpdates += 1
        #endif
        #if DEBUG || NOOK_PERFORMANCE_TRACE
        MainThreadLog.add("list.title.native.bind", ms: 0)
        #endif
        guard self.box !== box || self.title != title || self.translator !== translator else { return }
        generation &+= 1
        self.title = title
        self.box = box
        self.translator = translator
        updateState(translator.textSnapshot(for: box, title: title))
        let token = generation
        // updateNSView itself tracks observable reads. Register outside that
        // SwiftUI update so text changes reach only this native view.
        Task { @MainActor [weak self] in
            guard let self, generation == token else { return }
            refresh()
        }
    }

    func unbind() {
        generation &+= 1
        box = nil
        translator = nil
    }

    private func refresh() {
        guard let box, let translator else { return }
        let token = generation
        let state = withObservationTracking {
            translator.state(for: box, title: title)
        } onChange: { [weak self] in
            // Observation fires before the write. Read the latest snapshot on
            // the next actor turn, and discard callbacks from a reused cell.
            Task { @MainActor [weak self] in
                guard let self, generation == token else { return }
                refresh()
            }
        }
        updateState(state)
    }

    private func updateState(_ state: ListTitleTranslator.TitleState?) {
        let text: String
        switch state {
        case .translating(let partial, _): text = partial
        case .translated(let final, _): text = final
        case nil: text = ""
        }
        updateText(text)
    }

    func updateText(_ text: String) {
        let placeholder = text.isEmpty
        guard renderedText != text || renderedPlaceholder != placeholder else { return }
        #if DEBUG || NOOK_PERFORMANCE_TRACE
        let started = ProcessInfo.processInfo.systemUptime
        defer { MainThreadLog.add("list.title.native.update", ms: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
        #endif
        let oldHeight = lastWidth.map { measuredSize(width: $0).height }
        renderedText = text
        renderedPlaceholder = placeholder
        label.stringValue = placeholder ? String(localized: "Translating…", bundle: .main) : text
        label.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: placeholder ? .regular : .medium
        )
        label.textColor = placeholder ? .secondaryLabelColor : .controlAccentColor
        sizes.removeAll(keepingCapacity: true)
        if let width = lastWidth, let oldHeight, measuredSize(width: width).height != oldHeight {
            #if DEBUG || NOOK_PERFORMANCE_TRACE
            MainThreadLog.add("list.title.native.height", ms: 0)
            #endif
            invalidateIntrinsicContentSize()
        }
    }

    func measuredSize(width proposed: CGFloat?) -> CGSize {
        let width = proposed.flatMap { $0.isFinite ? max(1, $0) : nil }
            ?? max(1, label.cell?.cellSize.width ?? 1)
        if let cached = sizes[width] { return cached }
        let size = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        let result = CGSize(width: width, height: ceil(size.height))
        sizes[width] = result
        return result
    }

    override var intrinsicContentSize: NSSize {
        measuredSize(width: lastWidth ?? (bounds.width > 0 ? bounds.width : nil))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changedWidth = lastWidth != newSize.width
        super.setFrameSize(newSize)
        label.frame = bounds
        lastWidth = newSize.width
        if changedWidth { invalidateIntrinsicContentSize() }
    }
}
#endif
