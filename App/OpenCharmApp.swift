import AppKit
import SwiftUI

/// `MenuBarExtra(.window)`'s content (`RecorderPanelView`) is lazily instantiated — its `body`
/// (and therefore its `onAppear`) only runs the first time the user actually clicks the menu bar
/// icon, not at launch. Recovery-on-launch must not depend on that click, so it's driven from
/// here instead, via the standard AppKit launch hook.
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
    }
}

@main
struct OpenCharmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RecorderPanelView(model: model)
        } label: {
            Image(systemName: model.engine.state == .idle
                  ? "record.circle" : "record.circle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
