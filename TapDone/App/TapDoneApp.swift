import AppKit

/// AppKit owns the single workspace window; SwiftUI renders its content only.
@main
struct TapDoneApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication.delegate is weak; keep it alive for the entire event loop.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
