import AppKit
import AVFoundation

/// Floating draggable webcam self-view shown while recording. Excluded from capture
/// by passing its windowNumber into RecordingConfiguration.excludedWindowNumbers.
final class SelfViewWindow: NSPanel {
    init(previewLayer: AVCaptureVideoPreviewLayer) {
        let size: CGFloat = 160
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        super.init(contentRect: NSRect(x: screenFrame.maxX - size - 24,
                                       y: screenFrame.minY + 24,
                                       width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = true
        hasShadow = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        previewLayer.frame = view.bounds
        previewLayer.cornerRadius = size / 2
        previewLayer.masksToBounds = true
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer!.addSublayer(previewLayer)
        contentView = view
    }
}
