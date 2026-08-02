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
struct WebcamDragOverlay: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        GeometryReader { geo in
            let canvas = model.sourceCanvasSize
            let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            let shown = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2,
                                 y: (geo.size.height - shown.height) / 2)
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        guard model.renderSettings.webcam.visible else { return }
                        let nx = (v.location.x - origin.x) / shown.width
                        let ny = (v.location.y - origin.y) / shown.height // top-left, matches settings
                        // Only react if the drag started on the bubble.
                        let layout = CanvasLayout.compute(
                            canvasSize: canvas, screenAspect: canvas.width / canvas.height,
                            settings: model.renderSettings)
                        let startNX = (v.startLocation.x - origin.x) / shown.width * canvas.width
                        let startNY = canvas.height - (v.startLocation.y - origin.y) / shown.height * canvas.height
                        guard layout.webcamRect.insetBy(dx: -20, dy: -20)
                            .contains(CGPoint(x: startNX, y: startNY)) else { return }
                        model.renderSettings.webcam.center = CGPoint(
                            x: min(1, max(0, nx)), y: min(1, max(0, ny)))
                    })
        }
    }
}
