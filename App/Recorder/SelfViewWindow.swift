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
        // Without this the bubble is pinned to the Space it was created on and stays hidden
        // over fullscreen apps: switching Spaces (four-finger swipe) or entering a fullscreen
        // app would leave the webcam behind. `.canJoinAllSpaces` makes it follow the user to
        // every Space; `.fullScreenAuxiliary` lets it float above fullscreen windows.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = true
        hasShadow = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        previewLayer.frame = view.bounds
        // Same squircle as the composited bubble (default roundness 0.65 → radius 0.325 × side);
        // .continuous gives the icon-like corner curvature, not a plain rounded rect.
        previewLayer.cornerRadius = size * 0.325
        previewLayer.cornerCurve = .continuous
        previewLayer.masksToBounds = true
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer!.addSublayer(previewLayer)
        contentView = view
    }

    /// Replaces the bubble's current preview layer with `layer` (used for the
    /// idle-session ↔ recording-session handoff).
    func swap(to layer: AVCaptureVideoPreviewLayer) {
        guard let view = contentView else { return }
        view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer.frame = view.bounds
        layer.cornerRadius = view.bounds.width * 0.325
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
    }
}
