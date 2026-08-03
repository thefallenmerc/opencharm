import AppKit
import SwiftUI

/// The UI is driven from here at launch — recovery check, the floating dock, and the live
/// webcam bubble — via the standard AppKit launch hook, rather than any lazy SwiftUI scene
/// content. (The `MenuBarExtra` is now a plain menu; its buttons run immediately.)
///
/// Reaching the app's single `AppModel` instance from an `NSApplicationDelegate` (which SwiftUI
/// itself constructs, independently of `OpenCharmApp`'s own property wrappers) needs a hand-off:
/// `AppModel.shared` is a simple self-registering static, set in `AppModel.init()` — which runs
/// well before `applicationDidFinishLaunching`, since `OpenCharmApp`'s `@StateObject` initial
/// value is constructed as part of the app's own startup, ahead of AppKit dispatching launch
/// notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared?.checkRecoveryOnLaunchOnce()
        AppModel.shared?.launchUI()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared?.applicationShouldTerminate() ?? .terminateNow
    }
}

@main
struct OpenCharmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Button("Show Dock") { model.showDock() }
            Button("Open Project…") { model.openProjectPanel() }
                .keyboardShortcut("o")
            Divider()
            Button("Quit OpenCharm") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.engine.state == .idle
                  ? "record.circle" : "record.circle.fill")
        }
    }
}
