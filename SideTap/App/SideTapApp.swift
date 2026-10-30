import SwiftUI

@main
struct SideTapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(store: delegate.store, updates: delegate.updates)
        }
    }
}
