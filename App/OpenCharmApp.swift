import SwiftUI

@main
struct OpenCharmApp: App {
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
