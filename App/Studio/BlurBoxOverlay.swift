import RenderCore
import SwiftUI

/// Editing chrome for privacy blur boxes on the preview canvas.
///
/// Two modes:
/// - **Drawing** (`model.isDrawingBlur`): the whole canvas becomes a crosshair surface; a drag
///   rubber-bands a rectangle and, on release, creates a 2-second blur box at the playhead.
/// - **Editing**: boxes active at the playhead (plus the selected one) are hit-testable —
///   clicking selects (syncing with the timeline lane), the selected box shows corner handles
///   to resize and drags to move. A tap on the selected box deselects it.
///
/// All geometry maps through the same zoom transform the compositor applies, so the chrome
/// stays glued to the (possibly magnified) content. Hit-testing is restricted to the box
/// regions themselves — everywhere else clicks pass through (see WebcamDragOverlay's note).
struct BlurBoxOverlay: View {
    @ObservedObject var model: StylingModel

    @State private var marquee: CGRect?       // draw-mode rubber band, view coords
    @State private var dragBase: BlurBoxSpec? // spec captured at gesture start; deltas don't compound

    var body: some View {
        GeometryReader { geo in
            let canvas = model.canvasSize
            let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            let shown = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2,
                                 y: (geo.size.height - shown.height) / 2)
            let layout = CanvasLayout.compute(
                canvasSize: canvas,
                screenAspect: model.sourceCanvasSize.width / max(model.sourceCanvasSize.height, 1),
                settings: model.renderSettings)
            // Content card in this view's space (top-left origin, y-down).
            let contentView = CGRect(
                x: origin.x + layout.contentRect.minX * scale,
                y: origin.y + (canvas.height - layout.contentRect.maxY) * scale,
                width: layout.contentRect.width * scale,
                height: layout.contentRect.height * scale)
            let zoom = model.zoomState(at: model.currentTime)
            let mapper = BlurBoxMapper(
                contentView: contentView,
                focus: CGPoint(x: contentView.minX + CGFloat(zoom.focus.x) * contentView.width,
                               y: contentView.minY + CGFloat(zoom.focus.y) * contentView.height),
                scale: CGFloat(zoom.scale))

            ZStack(alignment: .topLeading) {
                if model.isDrawingBlur {
                    drawSurface(mapper: mapper)
                } else {
                    ForEach(hitBoxes) { spec in
                        boxChrome(spec, mapper: mapper)
                    }
                }
            }
        }
    }

    /// Boxes the canvas should hit-test right now: whatever is active at the playhead, plus
    /// the selected one (kept editable even when the playhead has moved out of its range).
    private var hitBoxes: [BlurBoxSpec] {
        let t = model.currentTime
        return model.blurBoxes.filter {
            ($0.start <= t && t <= $0.end) || $0.id == model.selectedBlurID
        }
    }

    // MARK: drawing

    private func drawSurface(mapper: BlurBoxMapper) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .cursor(.crosshair)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        marquee = CGRect(corner: v.startLocation, opposite: v.location)
                    }
                    .onEnded { v in
                        defer { marquee = nil; model.isDrawingBlur = false }
                        let r = CGRect(corner: v.startLocation, opposite: v.location)
                        let a = mapper.norm(r.origin).clamped01()
                        let b = mapper.norm(CGPoint(x: r.maxX, y: r.maxY)).clamped01()
                        let n = CGRect(corner: a, opposite: b)
                        guard n.width > 0.01, n.height > 0.01 else { return }
                        model.addBlurBox(rect: n)
                    })
            if let m = marquee {
                RoundedRectangle(cornerRadius: 4)
                    .fill(StudioTheme.accent.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(StudioTheme.accent,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                    .frame(width: m.width, height: m.height)
                    .offset(x: m.minX, y: m.minY)
            }
        }
    }

    // MARK: editing

    private func boxChrome(_ spec: BlurBoxSpec, mapper: BlurBoxMapper) -> some View {
        let vr = mapper.viewRect(spec.rect)
        let selected = model.selectedBlurID == spec.id
        return ZStack(alignment: .topLeading) {
            // Visual outline: positioned, never hit-tested.
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? StudioTheme.accent.opacity(0.10) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? StudioTheme.accent : .white.opacity(0.45),
                                  style: selected
                                      ? StrokeStyle(lineWidth: 2)
                                      : StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(width: vr.width, height: vr.height)
                .offset(x: vr.minX, y: vr.minY)
                .allowsHitTesting(false)

            // Hit surface: spans the whole overlay (so gesture locations stay in overlay
            // coordinates, which the mapper expects) but only the box region is testable.
            if selected {
                Color.clear
                    .contentShape(BlurHitShape(rect: vr))
                    .cursor(.pointingHand)
                    .gesture(moveDrag(spec, mapper: mapper))
            } else {
                Color.clear
                    .contentShape(BlurHitShape(rect: vr))
                    .cursor(.pointingHand)
                    .onTapGesture { model.selectBlur(spec.id) }
            }

            if selected {
                ForEach(0..<4, id: \.self) { i in
                    let corner = CGPoint(x: i % 2 == 0 ? vr.minX : vr.maxX,
                                         y: i < 2 ? vr.minY : vr.maxY)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                        .frame(width: 11, height: 11)
                        .frame(width: 22, height: 22) // easier grab
                        .contentShape(Rectangle())
                        .position(corner)
                        .gesture(resizeDrag(spec, cornerIndex: i, mapper: mapper))
                }
            }
        }
    }

    /// Dragging the selected box's interior moves it; a no-move tap deselects.
    private func moveDrag(_ spec: BlurBoxSpec, mapper: BlurBoxMapper) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragBase == nil { dragBase = spec }
                guard let base = dragBase, base.id == spec.id else { return }
                let d = mapper.normDelta(v.translation)
                var r = base.rect.offsetBy(dx: d.width, dy: d.height)
                r.origin.x = min(max(0, r.origin.x), 1 - r.width)
                r.origin.y = min(max(0, r.origin.y), 1 - r.height)
                var s = base
                s.rect = r
                model.updateBlurBox(s)
            }
            .onEnded { v in
                dragBase = nil
                if abs(v.translation.width) + abs(v.translation.height) < 3 {
                    model.selectBlur(nil)
                }
            }
    }

    /// Dragging a corner resizes about the opposite (fixed) corner.
    private func resizeDrag(_ spec: BlurBoxSpec, cornerIndex i: Int,
                            mapper: BlurBoxMapper) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragBase == nil { dragBase = spec }
                guard let base = dragBase, base.id == spec.id else { return }
                let anchor = CGPoint(x: i % 2 == 0 ? base.rect.maxX : base.rect.minX,
                                     y: i < 2 ? base.rect.maxY : base.rect.minY)
                let p = mapper.norm(v.location).clamped01()
                let minSide = 0.02
                var r = CGRect(corner: anchor, opposite: p)
                if r.width < minSide {
                    r.origin.x = p.x < anchor.x ? anchor.x - minSide : anchor.x
                    r.size.width = minSide
                }
                if r.height < minSide {
                    r.origin.y = p.y < anchor.y ? anchor.y - minSide : anchor.y
                    r.size.height = minSide
                }
                var s = base
                s.rect = r
                model.updateBlurBox(s)
            }
            .onEnded { _ in dragBase = nil }
    }
}

/// Maps content-normalized rects (0…1, top-left origin) into the overlay view's coordinates,
/// through the preview's current zoom (a uniform scale about a focus point — applying it in
/// view space is equivalent to the compositor's canvas-space transform).
private struct BlurBoxMapper {
    let contentView: CGRect
    let focus: CGPoint
    let scale: CGFloat

    private func zoomed(_ p: CGPoint) -> CGPoint {
        CGPoint(x: focus.x + (p.x - focus.x) * scale, y: focus.y + (p.y - focus.y) * scale)
    }

    private func unzoomed(_ p: CGPoint) -> CGPoint {
        CGPoint(x: focus.x + (p.x - focus.x) / scale, y: focus.y + (p.y - focus.y) / scale)
    }

    func viewRect(_ n: CGRect) -> CGRect {
        let a = zoomed(CGPoint(x: contentView.minX + n.minX * contentView.width,
                               y: contentView.minY + n.minY * contentView.height))
        let b = zoomed(CGPoint(x: contentView.minX + n.maxX * contentView.width,
                               y: contentView.minY + n.maxY * contentView.height))
        return CGRect(corner: a, opposite: b)
    }

    /// View point → content-normalized (unclamped; callers clamp).
    func norm(_ p: CGPoint) -> CGPoint {
        let u = unzoomed(p)
        return CGPoint(x: (u.x - contentView.minX) / contentView.width,
                       y: (u.y - contentView.minY) / contentView.height)
    }

    /// View-space drag translation → content-normalized delta.
    func normDelta(_ t: CGSize) -> CGSize {
        CGSize(width: t.width / scale / contentView.width,
               height: t.height / scale / contentView.height)
    }
}

/// Restricts hit-testing to `rect` while the shape-bearing view keeps its own frame (same
/// trick as WebcamDragOverlay.BubbleHitShape).
private struct BlurHitShape: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}

private extension CGRect {
    init(corner a: CGPoint, opposite b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

private extension CGPoint {
    func clamped01() -> CGPoint {
        CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}
