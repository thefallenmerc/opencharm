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

        Window("OpenCharm Studio", id: "styling") {
            StylingHost(model: model)
        }
        .defaultSize(width: 1100, height: 700)
    }
}

struct StylingHost: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let pkg = model.finishedProject {
                StylingView(model: StylingModel(package: pkg))
                    .id(pkg.url) // new model per project
            } else {
                Text("Record something, or open a .opencharm project.")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
    }
}
