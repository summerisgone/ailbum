import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A bare executable (swift run) is not a bundle: make it a regular app and
    // bring it forward only after launch, otherwise the window stays behind.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct AilbumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Ailbum") {
            AppShell()
                .frame(minWidth: 1000, minHeight: 650)
        }
    }
}
