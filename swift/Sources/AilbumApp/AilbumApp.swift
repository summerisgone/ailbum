import AppKit
import SwiftUI

@main
struct AilbumApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Ailbum") {
            LibraryView()
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
