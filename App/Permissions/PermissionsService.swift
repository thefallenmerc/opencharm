import AVFoundation
import AppKit
import CoreGraphics

enum PermissionKind: CaseIterable { case screenRecording, camera, microphone }
enum PermissionStatus { case granted, denied, undetermined }

enum PermissionsService {
    static func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }

    static func request(_ kind: PermissionKind) async -> Bool {
        switch kind {
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    static func openSystemSettings(_ kind: PermissionKind) {
        let pane: String
        switch kind {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        }
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private static func map(_ s: AVAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }
}
