import AVKit
import RenderCore
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none // the Studio timeline drives playback
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
            let canvas = model.canvasSize
            let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            let shown = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2,
                                 y: (geo.size.height - shown.height) / 2)
            let minDim = min(canvas.width, canvas.height)
            // Recomputed on every render (not just inside the gesture) so the hit-test region
            // always tracks the CURRENT settings, not a stale bubble position from before the
            // last drag or a settings change made elsewhere (e.g. the styling sidebar).
            let layout = CanvasLayout.compute(
                canvasSize: canvas, screenAspect: canvas.width / canvas.height,
                settings: model.renderSettings)
            // `layout.webcamRect` is canvas-space, y-up (see CanvasLayout's doc comment);
            // convert to this view's space, which is top-left origin / y-down, same conversion
            // `onChanged` below already does for a single point, applied to the whole rect.
            let visualRect = CGRect(
                x: origin.x + layout.webcamRect.minX * scale,
                y: origin.y + (canvas.height - layout.webcamRect.maxY) * scale,
                width: layout.webcamRect.width * scale,
                height: layout.webcamRect.height * scale)
            let bubbleViewRect = visualRect.insetBy(dx: -20, dy: -20)
            let center = CGPoint(x: visualRect.midX, y: visualRect.midY)

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(BubbleHitShape(rect: bubbleViewRect))
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            guard model.renderSettings.webcam.visible else { return }
                            let nx = (v.location.x - origin.x) / shown.width
                            let ny = (v.location.y - origin.y) / shown.height // top-left, matches settings
                            model.renderSettings.webcam.center = CGPoint(
                                x: min(1, max(0, nx)), y: min(1, max(0, ny)))
                        }
                        .onEnded { _ in
                            // The bubble lives in a corner: on release it snaps to the layout
                            // corner of whichever quadrant it was dropped in.
                            guard model.renderSettings.webcam.visible else { return }
                            let c = model.renderSettings.webcam.center
                            model.renderSettings.webcam.center = CGPoint(
                                x: c.x < 0.5 ? 0.13 : 0.87,
                                y: c.y < 0.5 ? 0.18 : 0.82)
                        })

                // Corner handles resize the bubble (they sit on top, so grabbing a corner resizes
                // while a drag on the interior still moves it).
                if model.renderSettings.webcam.visible {
                    ForEach(0..<4, id: \.self) { i in
                        WebcamResizeHandle(
                            center: center,
                            corner: CGPoint(x: i % 2 == 0 ? visualRect.minX : visualRect.maxX,
                                            y: i < 2 ? visualRect.minY : visualRect.maxY),
                            scale: scale, minDim: minDim
                        ) { model.renderSettings.webcam.size = $0 }
                    }
                }
            }
        }
    }
}

/// A draggable corner dot that resizes the webcam bubble about its center. `apply` receives the new
/// `webcam.size` (fraction of the canvas min dimension), clamped to a sane range.
private struct WebcamResizeHandle: View {
    let center: CGPoint
    let corner: CGPoint
    let scale: CGFloat
    let minDim: CGFloat
    let apply: (Double) -> Void

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
            .frame(width: 12, height: 12)
            .frame(width: 24, height: 24)          // larger, easier-to-grab hit area
            .contentShape(Rectangle())
            .position(corner)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let dx = v.location.x - center.x
                    let dy = v.location.y - center.y
                    let sideView = max(abs(dx), abs(dy)) * 2      // square bubble, center-anchored
                    apply(min(0.6, max(0.1, Double(sideView / scale / minDim))))
                })
    }
}
