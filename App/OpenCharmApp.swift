import AppKit
import ProjectStore
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

        Window("OpenCharm Studio", id: "styling") {
            StylingHost(model: model)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { model.openProjectPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}

struct StylingHost: View {
    @ObservedObject var model: AppModel
    // Held via @State so the cache instance itself is stable across re-renders; mutating its
    // internal dictionary in `model(for:)` is a plain method call on that stable reference, not
    // a State write, so it's safe to call from `body`.
    @State private var cache = StylingModelCache()

    var body: some View {
        Group {
            if let pkg = model.finishedProject {
                // `cache.model(for:)` reuses the existing StylingModel for this project instead
                // of constructing a new one (with its own AVPlayer + initialLoad() task) on
                // every AppModel publish that re-evaluates this body — the classic @StateObject
                // inline-init pitfall, since `StylingModel(package: pkg)` would otherwise run
                // its side-effecting init eagerly even when SwiftUI ends up discarding the
                // instance.
                StylingView(model: cache.model(for: pkg))
                    .id(pkg.url) // stable view identity per project
            } else {
                Text("Record something, or open a .opencharm project.")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
    }
}

/// Stable-per-identity cache of `StylingModel`s keyed by project URL, so `StylingHost` can hand
/// `StylingView` the *same* model instance across re-renders instead of constructing (and
/// discarding) a new one — see `StylingHost.body`.
@MainActor
private final class StylingModelCache {
    private var models: [URL: StylingModel] = [:]

    func model(for pkg: ProjectPackage) -> StylingModel {
        if let existing = models[pkg.url] { return existing }
        let created = StylingModel(package: pkg)
        models[pkg.url] = created
        return created
    }
}
