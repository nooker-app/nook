#if DEBUG
import Foundation

/// Launch arguments of a `tools/perf/run.sh` child. Every perf-only gate goes
/// through here so they all agree on when a run is in progress.
public enum PerfLaunch {
    /// A perf run always names its working library. The key must appear as its
    /// own argument followed by a value, so the string showing up inside
    /// another flag's value does not count.
    public static var isActive: Bool { value(for: "-NookPerfLibrary") != nil }

    public static var isBackground: Bool { isActive && value(for: "-NookPerfBackground") == "YES" }

    /// The value after `key` in this process's arguments, if any.
    public static func value(for key: String) -> String? {
        value(for: key, in: ProcessInfo.processInfo.arguments)
    }

    static func value(for key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif
