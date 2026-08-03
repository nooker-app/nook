import CoreGraphics
import Foundation

// Prints the CGWindowID of the frontmost on-screen window owned by the named
// application, so screencapture -l can grab that window and nothing else.
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Nook"
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for window in windows {
    guard let name = window[kCGWindowOwnerName as String] as? String, name == owner,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
        width > 400, height > 300,
        let id = window[kCGWindowNumber as String] as? Int
    else { continue }
    print(id)
    exit(0)
}
FileHandle.standardError.write(Data("no window for \(owner)\n".utf8))
exit(1)
