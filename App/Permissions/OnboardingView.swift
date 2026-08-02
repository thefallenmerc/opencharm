import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var statuses: [PermissionKind: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions").font(.headline)
            row(.screenRecording, "Screen Recording")
            row(.camera, "Camera")
            row(.microphone, "Microphone")
            Text("Grant in System Settings, then reopen this panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
        // Granting a permission happens in System Settings, outside the app. When the
        // user switches back, re-check so rows go green and the dock's gated source
        // actions unlock without the user having to relaunch or reopen the popover.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
            model.permissionsChanged()
        }
    }

    func row(_ kind: PermissionKind, _ label: String) -> some View {
        HStack {
            Image(systemName: statuses[kind] == .granted
                  ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(statuses[kind] == .granted ? .green : .red)
            Text(label)
            Spacer()
            if statuses[kind] != .granted {
                Button("Grant") {
                    Task {
                        _ = await PermissionsService.request(kind)
                        PermissionsService.openSystemSettings(kind)
                        refresh()
                        model.permissionsChanged()
                    }
                }
            }
        }
    }

    func refresh() {
        for k in PermissionKind.allCases { statuses[k] = PermissionsService.status(k) }
    }
}
