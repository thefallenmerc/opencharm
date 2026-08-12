import SwiftUI

/// The preview stage: the player floating on the window background with rounded corners,
/// drag/resize overlays on top. The overlay must share the player's aspect-fitted container so
/// its geometry math keeps matching the video frame.
struct StudioCanvas: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ZStack {
            StudioTheme.windowBG
            ZStack {
                PlayerView(player: model.player)
                WebcamDragOverlay(model: model)
            }
            .aspectRatio(model.canvasSize.width / max(model.canvasSize.height, 1),
                         contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(24)
            if model.processingAudio {
                ProgressView("Processing audio…")
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
