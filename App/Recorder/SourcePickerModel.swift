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

    func refresh() async {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        mics = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        if cameraID == nil { cameraID = cameras.first?.uniqueID }
        if micID == nil { micID = mics.first?.uniqueID }
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
        return RecordingConfiguration(
            source: source,
            webcamDeviceID: cameraEnabled ? cameraID : nil,
            micDeviceID: micEnabled ? micID : nil,
            capturesSystemAudio: systemAudio, fps: fps,
            excludedWindowNumbers: excludedWindowNumbers)
    }
}
