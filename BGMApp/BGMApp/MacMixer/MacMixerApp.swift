import SwiftUI

@main
struct MacMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar status item + popover are managed by AppDelegate.
        // This empty Settings scene satisfies the App protocol without showing
        // a window.
        Settings { EmptyView() }
    }
}
