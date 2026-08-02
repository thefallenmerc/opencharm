import AVKit
import RenderCore
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

/// Transparent overlay translating drags into normalized webcam centers.
///
/// Hit-testing is restricted to the webcam bubble's own rect (+20pt slop): earlier this view's
/// `contentShape` covered the whole canvas, so it silently swallowed every click in the player
/// area — including clicks meant for the underlying `AVPlayerView`'s transport controls (play/
/// pause, scrubber). Only the bubble region itself should intercept gestures; everywhere else
/// must pass clicks through to the player.
struct WebcamDragOverlay: View {
    @ObservedObject var model: StylingModel

    /// `contentShape(_:)` calls `path(in:)` with the shape-bearing view's own bounds; this
    /// ignores that rect and always returns the caller-supplied one, so a view can keep its
    /// full frame (needed so `DragGesture`'s `location`/`startLocation` stay in the same
    /// coordinate space the rest of this file's math already assumes) while only a sub-region
    /// of it is actually hit-testable.
    private struct BubbleHitShape: Shape {
        let rect: CGRect
        func path(in _: CGRect) -> Path { Path(rect) }
    }

    var body: some View {
        GeometryReader { geo in
            let canvas = model.sourceCanvasSize
            let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            let shown = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2,
                                 y: (geo.size.height - shown.height) / 2)
            // Recomputed on every render (not just inside the gesture) so the hit-test region
            // always tracks the CURRENT settings, not a stale bubble position from before the
            // last drag or a settings change made elsewhere (e.g. the styling sidebar).
            let layout = CanvasLayout.compute(
                canvasSize: canvas, screenAspect: canvas.width / canvas.height,
                settings: model.renderSettings)
            // `layout.webcamRect` is canvas-space, y-up (see CanvasLayout's doc comment);
            // convert to this view's space, which is top-left origin / y-down, same conversion
            // `onChanged` below already does for a single point, applied to the whole rect.
            let bubbleViewRect = CGRect(
                x: origin.x + layout.webcamRect.minX * scale,
                y: origin.y + (canvas.height - layout.webcamRect.maxY) * scale,
                width: layout.webcamRect.width * scale,
                height: layout.webcamRect.height * scale
            ).insetBy(dx: -20, dy: -20)

            Color.clear
                .contentShape(BubbleHitShape(rect: bubbleViewRect))
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        guard model.renderSettings.webcam.visible else { return }
                        let nx = (v.location.x - origin.x) / shown.width
                        let ny = (v.location.y - origin.y) / shown.height // top-left, matches settings
                        model.renderSettings.webcam.center = CGPoint(
                            x: min(1, max(0, nx)), y: min(1, max(0, ny)))
                    })
        }
    }
}
