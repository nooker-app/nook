import Darwin
import SwiftUI
import WidgetKit

/// Home's host-level blur request. All private imports are weak-linked by the
/// widget-only SDK overlay; no modified Apple framework is bundled in the app.
enum NookWidgetHostBackground {
    static let isAvailable: Bool = {
        let symbols = [
            "$s7SwiftUI19WidgetConfigurationP0C3KitE24preferredBackgroundStyleyQrAD0cgH0OF",
            "$s7SwiftUI19WidgetConfigurationP0C3KitE24preferredBackgroundStyleyQrAD0cgH0OFQOMQ",
            "$s9WidgetKit0A15BackgroundStyleO4bluryA2CmFWC",
            "$s9WidgetKit0A15BackgroundStyleOMa",
        ]
        return symbols.allSatisfy { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) != nil }
    }()
}

extension WidgetConfiguration {
    func nookHostBackground() -> some WidgetConfiguration {
        NookHostBackgroundConfiguration(content: self)
    }
}

/// Keep the opaque private result out of stored properties and the public body
/// type. SwiftUI must be able to construct this configuration even when that
/// result's runtime metadata no longer exists on a future OS.
private struct NookHostBackgroundConfiguration<Content: WidgetConfiguration>: WidgetConfiguration {
    nonisolated(unsafe) let content: Content

    var body: Never { fatalError("Primitive widget configuration") }

    nonisolated private var blurred: some WidgetConfiguration {
        content.preferredBackgroundStyle(.blur)
    }

    nonisolated static func _makeWidgetConfiguration(
        widget: _GraphValue<Self>, inputs: _WidgetInputs
    ) -> _WidgetOutputs {
        if NookWidgetHostBackground.isAvailable {
            return makeBlur(widget: widget, inputs: inputs)
        }
        return Content._makeWidgetConfiguration(widget: widget[\.content], inputs: inputs)
    }

    // Do not specialize the unavailable private opaque type in the fallback
    // branch. The computed-property projection is formed only after the guard.
    @inline(never)
    nonisolated private static func makeBlur(
        widget: _GraphValue<Self>, inputs: _WidgetInputs
    ) -> _WidgetOutputs {
        func make<Configuration: WidgetConfiguration>(_ value: _GraphValue<Configuration>) -> _WidgetOutputs {
            Configuration._makeWidgetConfiguration(widget: value, inputs: inputs)
        }
        return make(widget[\.blurred])
    }
}
