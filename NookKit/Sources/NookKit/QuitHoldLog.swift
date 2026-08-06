#if DEBUG && os(macOS)
    import AppKit

    /// A temporary record of what happens when ⌘Q is pressed.
    ///
    /// Here because ⌘Q does nothing in a freshly opened composer and my reading of why was
    /// wrong once already: the guard's unprotected path handed the shortcut to the Quit menu
    /// item, that was changed to terminate directly, and the symptom did not move. A posted
    /// ⌘Q never reaches the app under a SwiftUI window, so a probe cannot answer this — the
    /// app has to say what it sees.
    ///
    /// Debug builds only. It records key codes, modifier bits and window state; nothing a
    /// person wrote.
    ///
    /// To read it: press ⌘Q in the composer, then quit some other way, and look for
    /// `nook-quit.log` under the app's container `tmp`.
    @MainActor
    public enum QuitHoldLog {
        private static var lines: [String] = []

        static var url: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("nook-quit.log")
        }

        /// One line, flushed immediately: the next thing that happens may be the process
        /// exiting, and a buffered log of a quit is a log that is never written.
        static func note(_ phase: String, _ detail: String = "") {
            let app = NSApp
            let key = app?.keyWindow
            lines.append(
                String(
                    format: "%.3f %-22@ %@ | key=%@ sheet=%@ modal=%@ main=%@ active=%@",
                    ProcessInfo.processInfo.systemUptime,
                    phase as NSString,
                    detail as NSString,
                    (key?.title ?? "nil") as NSString,
                    (key?.attachedSheet != nil ? "yes" : "no") as NSString,
                    (app?.modalWindow?.title ?? "nil") as NSString,
                    (app?.mainWindow?.title ?? "nil") as NSString,
                    (app?.isActive == true ? "yes" : "no") as NSString))
            flush()
        }

        /// Called from the app delegate, which is in another module and should not have to
        /// know the shape of a log line.
        public static func noteTerminationReachedDelegate() {
            note("terminate.delegate", "applicationShouldTerminate reached")
        }

        static func flush() {
            guard !lines.isEmpty, let data = (lines.joined(separator: "\n") + "\n")
                .data(using: .utf8)
            else { return }
            lines.removeAll()
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
#endif
