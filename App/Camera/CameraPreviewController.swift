import AppKit
import AVFoundation

/// Owns the idle (non-recording) camera preview session and THE self-view bubble
/// used in both idle and recording modes. The Recording package is never touched:
/// at record start the idle session stops (releasing the device), the engine's
/// recording preview layer is swapped into the same bubble, and on stop the idle
/// session resumes. A sub-second preview gap during handoff is by design.
@MainActor
final class CameraPreviewController {
    private(set) var bubble: SelfViewWindow?
    private var session: AVCaptureSession?
    private var idleLayer: AVCaptureVideoPreviewLayer?

    var bubbleWindowNumber: Int? { bubble?.windowNumber }

    /// Starts (or restarts) the idle preview on `deviceID` (nil = default camera)
    /// and shows the bubble. No-op degradation: if the device can't be opened the
    /// bubble is hidden and the app stays functional.
    func startIdlePreview(deviceID: String?) {
        stopIdleSession()
        guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) })
            ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device) else {
            hideBubble()
            return
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        guard s.canAddInput(input) else { s.commitConfiguration(); hideBubble(); return }
        s.addInput(input)
        s.commitConfiguration()
        let layer = AVCaptureVideoPreviewLayer(session: s)
        layer.videoGravity = .resizeAspectFill
        ensureBubble().swap(to: layer)
        session = s
        idleLayer = layer
        Task.detached { s.startRunning() } // blocking call; keep off the main actor
    }

    /// Stops the idle session (turns the camera light off). Bubble stays unless hidden.
    func stopIdleSession() {
        session?.stopRunning()
        session = nil
        idleLayer = nil
    }

    /// Swaps the engine's recording preview layer into the (existing) bubble.
    func attachRecordingLayer(_ layer: AVCaptureVideoPreviewLayer) {
        ensureBubble().swap(to: layer)
    }

    func hideBubble() {
        bubble?.orderOut(nil)
    }

    /// Creates the bubble on first use; re-shows it if hidden.
    @discardableResult
    func ensureBubble() -> SelfViewWindow {
        let b: SelfViewWindow
        if let bubble { b = bubble } else {
            b = SelfViewWindow(previewLayer: AVCaptureVideoPreviewLayer())
            bubble = b
        }
        b.orderFront(nil)
        return b
    }
}
