import SwiftUI

@main
struct OpenCharmApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("OpenCharm", systemImage: "record.circle") {
            Text("OpenCharm 0.1 — recorder UI lands in Task 14")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
