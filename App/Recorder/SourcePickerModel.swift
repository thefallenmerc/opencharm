import AVFoundation
import Recording
import ScreenCaptureKit
import SwiftUI

@MainActor
final class SourcePickerModel: ObservableObject {
    enum Mode: String, CaseIterable { case fullScreen = "Screen", window = "Window", area = "Area" }

    @Published var mode: Mode = .fullScreen
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var selectedWindow: SCWindow?
    @Published var selectedArea: CGRect?           // display points, top-left origin
    @Published var cameras: [AVCaptureDevice] = []
    @Published var mics: [AVCaptureDevice] = []
    @Published var cameraID: String?               // nil = off
    @Published var micID: String?
    @Published var systemAudio = true
    @Published var fps = 60
    /// Master switches for the dock toggles. Device *selection* (`cameraID`/`micID`)
    /// is preserved while a source is toggled off.
    @Published var cameraEnabled = true
    @Published var micEnabled = true

    /// Re-enumerates cameras/mics (cheap, synchronous) and keeps the selection valid: an existing
    /// selection is preserved if the device is still present, otherwise it falls back to the first
    /// available (or nil). Called at launch and whenever a device is plugged in/out.
    func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        mics = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        if cameraID == nil || !cameras.contains(where: { $0.uniqueID == cameraID }) {
            cameraID = cameras.first?.uniqueID
        }
        if micID == nil || !mics.contains(where: { $0.uniqueID == micID }) {
            micID = mics.first?.uniqueID
        }
    }

    func refresh() async {
        refreshDevices()
        if let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) {
            displays = content.displays
            windows = content.windows.filter {
                $0.isOnScreen && ($0.title?.isEmpty == false)
                    && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
        }
    }

    func buildConfiguration(excludedWindowNumbers: [Int]) -> RecordingConfiguration? {
        let source: RecordingConfiguration.Source
        switch mode {
        case .fullScreen:
            source = .display(selectedDisplayID)
        case .window:
            guard let selectedWindow else { return nil }
            source = .window(selectedWindow)
        case .area:
            guard let selectedArea else { return nil }
            source = .area(displayID: selectedDisplayID, rect: selectedArea)
        }
        // Camera/mic are optional: without their permission the recording proceeds without
        // those tracks instead of blocking (or failing to open the device mid-start).
        let cameraOK = PermissionsService.status(.camera) == .granted
        let micOK = PermissionsService.status(.microphone) == .granted
        return RecordingConfiguration(
            source: source,
            webcamDeviceID: cameraEnabled && cameraOK ? cameraID : nil,
            micDeviceID: micEnabled && micOK ? micID : nil,
            capturesSystemAudio: systemAudio, fps: fps,
            excludedWindowNumbers: excludedWindowNumbers)
    }
}
