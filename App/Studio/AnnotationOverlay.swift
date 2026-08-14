import RenderCore
import SwiftUI

/// Editing chrome for privacy blur boxes AND drawn annotations (text, shapes, arrows,
/// spotlight) on the preview canvas — one overlay, since both share the same
/// draw/select/move/resize idiom and content-space coordinate math.
///
/// Two modes:
/// - **Drawing** (`model.drawTool != nil`): the whole canvas becomes a crosshair surface; a
///   drag rubber-bands a rectangle (or, for arrows, a line) and, on release, creates a
///   2-second box/shape/arrow at the playhead.
/// - **Editing**: boxes/annotations active at the playhead (plus the selected one) are
///   hit-testable — clicking selects (syncing with the timeline lanes), the selected one shows
///   handles to resize (corners for boxes, endpoints for arrows) and drags to move. A tap on
///   the selected item deselects it. Double-clicking a selected text annotation opens an inline
///   editor popover.
///
/// All geometry maps through the same zoom transform the compositor applies, so the chrome
/// stays glued to the (possibly magnified) content. Hit-testing is restricted to each item's
/// own region — everywhere else clicks pass through (see WebcamDragOverlay's note).
struct AnnotationOverlay: View {
    @ObservedObject var model: StylingModel

    @State private var marquee: CGRect?                    // draw-mode rubber band, view coords
    @State private var arrowPreview: (CGPoint, CGPoint)?    // draw-mode arrow line, view coords
    @State private var dragBase: BlurBoxSpec?               // blur drag anchor; deltas don't compound
    @State private var dragBaseAnnotation: AnnotationSpec?  // annotation drag anchor
    @State private var editingTextID: String?               // text annotation with the edit popover open

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
            let mapper = ContentMapper(
                contentView: contentView,
                focus: CGPoint(x: contentView.minX + CGFloat(zoom.focus.x) * contentView.width,
                               y: contentView.minY + CGFloat(zoom.focus.y) * contentView.height),
                scale: CGFloat(zoom.scale))

            ZStack(alignment: .topLeading) {
                if model.drawTool != nil {
                    drawSurface(mapper: mapper)
                } else {
                    ForEach(hitBoxes) { spec in
                        boxChrome(spec, mapper: mapper)
                    }
                    ForEach(hitAnnotations) { spec in
                        annotationChrome(spec, mapper: mapper)
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

    /// Same gating as `hitBoxes`, for annotations. Unresolved (future-version) kinds are
    /// skipped — nothing to draw chrome for.
    private var hitAnnotations: [AnnotationSpec] {
        let t = model.currentTime
        return model.annotations.filter {
            $0.resolvedKind != nil && (($0.start <= t && t <= $0.end) || $0.id == model.selectedAnnotationID)
        }
    }

    // MARK: drawing

    private func drawSurface(mapper: ContentMapper) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .cursor(.crosshair)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if model.drawTool?.annotationKind == .arrow {
                            arrowPreview = (v.startLocation, v.location)
                        } else {
                            marquee = CGRect(corner: v.startLocation, opposite: v.location)
                        }
                    }
                    .onEnded { v in
                        let tool = model.drawTool
                        defer { marquee = nil; arrowPreview = nil; model.drawTool = nil }
                        guard let tool else { return }
                        if tool == .blur {
                            let r = CGRect(corner: v.startLocation, opposite: v.location)
                            let a = mapper.norm(r.origin).clamped01()
                            let b = mapper.norm(CGPoint(x: r.maxX, y: r.maxY)).clamped01()
                            let n = CGRect(corner: a, opposite: b)
                            guard n.width > 0.01, n.height > 0.01 else { return }
                            model.addBlurBox(rect: n)
                            return
                        }
                        guard let kind = tool.annotationKind else { return }
                        if kind == .arrow {
                            let p1 = mapper.norm(v.startLocation).clamped01()
                            let p2 = mapper.norm(v.location).clamped01()
                            guard hypot(p2.x - p1.x, p2.y - p1.y) > 0.01 else { return }
                            let rect = CGRect(corner: p1, opposite: p2)
                            model.addAnnotation(kind: .arrow, rect: rect, arrowStart: p1, arrowEnd: p2)
                            return
                        }
                        let r = CGRect(corner: v.startLocation, opposite: v.location)
                        let a = mapper.norm(r.origin).clamped01()
                        let b = mapper.norm(CGPoint(x: r.maxX, y: r.maxY)).clamped01()
                        var n = CGRect(corner: a, opposite: b)
                        if kind == .text, n.width < 0.01 || n.height < 0.01 {
                            n = CGRect(x: a.x, y: a.y, width: 0.25, height: 0.08)
                            n.origin.x = min(max(0, n.origin.x), 1 - n.width)
                            n.origin.y = min(max(0, n.origin.y), 1 - n.height)
                        }
                        guard n.width > 0.01, n.height > 0.01 else { return }
                        model.addAnnotation(kind: kind, rect: n)
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
            if let (p1, p2) = arrowPreview {
                Path { p in p.move(to: p1); p.addLine(to: p2) }
                    .stroke(StudioTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 3]))
            }
        }
    }

    // MARK: blur editing (unchanged behavior)

    private func boxChrome(_ spec: BlurBoxSpec, mapper: ContentMapper) -> some View {
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
                    .contentShape(RegionHitShape(rect: vr))
                    .cursor(.pointingHand)
                    .gesture(moveDrag(spec, mapper: mapper))
            } else {
                Color.clear
                    .contentShape(RegionHitShape(rect: vr))
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
    private func moveDrag(_ spec: BlurBoxSpec, mapper: ContentMapper) -> some Gesture {
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
                            mapper: ContentMapper) -> some Gesture {
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

    // MARK: annotation editing

    @ViewBuilder
    private func annotationChrome(_ spec: AnnotationSpec, mapper: ContentMapper) -> some View {
        if spec.resolvedKind == .arrow {
            arrowChrome(spec, mapper: mapper)
        } else {
            annotationBoxChrome(spec, mapper: mapper)
        }
    }

    /// Rect-based kinds (text, rectangle, ellipse, spotlight): same chrome shape as a blur box.
    private func annotationBoxChrome(_ spec: AnnotationSpec, mapper: ContentMapper) -> some View {
        let vr = mapper.viewRect(spec.rect)
        let selected = model.selectedAnnotationID == spec.id
        return ZStack(alignment: .topLeading) {
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

            if selected {
                Color.clear
                    .contentShape(RegionHitShape(rect: vr))
                    .cursor(.pointingHand)
                    .gesture(annotationMoveDrag(spec, mapper: mapper))
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        if spec.resolvedKind == .text { editingTextID = spec.id }
                    })
            } else {
                Color.clear
                    .contentShape(RegionHitShape(rect: vr))
                    .cursor(.pointingHand)
                    .onTapGesture { model.selectAnnotation(spec.id) }
            }

            if selected {
                ForEach(0..<4, id: \.self) { i in
                    let corner = CGPoint(x: i % 2 == 0 ? vr.minX : vr.maxX,
                                         y: i < 2 ? vr.minY : vr.maxY)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                        .frame(width: 11, height: 11)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .position(corner)
                        .gesture(annotationResizeDrag(spec, cornerIndex: i, mapper: mapper))
                }
            }
        }
        .popover(isPresented: Binding(
            get: { editingTextID == spec.id },
            set: { if !$0 { editingTextID = nil } })) {
            textEditPopover(spec)
        }
    }

    private func textEditPopover(_ spec: AnnotationSpec) -> some View {
        TextField("Text", text: Binding(
            get: { spec.text ?? "" },
            set: { newValue in
                guard model.annotations.contains(where: { $0.id == spec.id }) else { return }
                var s = spec
                s.text = newValue
                model.updateAnnotation(s)
            }))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .frame(width: 200)
            .padding(10)
            .onSubmit { editingTextID = nil }
    }

    /// Dragging the selected box's interior moves it; a no-move tap deselects.
    private func annotationMoveDrag(_ spec: AnnotationSpec, mapper: ContentMapper) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragBaseAnnotation == nil { dragBaseAnnotation = spec }
                guard let base = dragBaseAnnotation, base.id == spec.id else { return }
                let d = mapper.normDelta(v.translation)
                var r = base.rect.offsetBy(dx: d.width, dy: d.height)
                r.origin.x = min(max(0, r.origin.x), 1 - r.width)
                r.origin.y = min(max(0, r.origin.y), 1 - r.height)
                var s = base
                s.rect = r
                model.updateAnnotation(s)
            }
            .onEnded { v in
                dragBaseAnnotation = nil
                if abs(v.translation.width) + abs(v.translation.height) < 3 {
                    model.selectAnnotation(nil)
                }
            }
    }

    /// Dragging a corner resizes about the opposite (fixed) corner.
    private func annotationResizeDrag(_ spec: AnnotationSpec, cornerIndex i: Int,
                                      mapper: ContentMapper) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragBaseAnnotation == nil { dragBaseAnnotation = spec }
                guard let base = dragBaseAnnotation, base.id == spec.id else { return }
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
                model.updateAnnotation(s)
            }
            .onEnded { _ in dragBaseAnnotation = nil }
    }

    /// The endpoints an arrow actually draws from — explicit `arrowStart`/`arrowEnd` when set,
    /// otherwise `rect`'s left/right mid-points (mirrors the renderer's default derivation).
    private func arrowPoints(_ spec: AnnotationSpec) -> (CGPoint, CGPoint) {
        if let s = spec.arrowStart, let e = spec.arrowEnd { return (s, e) }
        let midY = (spec.rect.minY + spec.rect.maxY) / 2
        return (CGPoint(x: spec.rect.minX, y: midY), CGPoint(x: spec.rect.maxX, y: midY))
    }

    private func arrowChrome(_ spec: AnnotationSpec, mapper: ContentMapper) -> some View {
        let (p1n, p2n) = arrowPoints(spec)
        let p1 = mapper.viewPoint(p1n)
        let p2 = mapper.viewPoint(p2n)
        let selected = model.selectedAnnotationID == spec.id
        return ZStack(alignment: .topLeading) {
            Path { p in p.move(to: p1); p.addLine(to: p2) }
                .stroke(selected ? StudioTheme.accent : .white.opacity(0.45),
                        style: selected
                            ? StrokeStyle(lineWidth: 3, lineCap: .round)
                            : StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
                .allowsHitTesting(false)

            if selected {
                Color.clear
                    .contentShape(LineHitShape(p1: p1, p2: p2, width: 16))
                    .cursor(.pointingHand)
                    .gesture(arrowMoveDrag(spec, mapper: mapper))
            } else {
                Color.clear
                    .contentShape(LineHitShape(p1: p1, p2: p2, width: 16))
                    .cursor(.pointingHand)
                    .onTapGesture { model.selectAnnotation(spec.id) }
            }

            if selected {
                ForEach([p1, p2].indices, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                        .frame(width: 11, height: 11)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .position(i == 0 ? p1 : p2)
                        .gesture(arrowEndpointDrag(spec, isStart: i == 0, mapper: mapper))
                }
            }
        }
    }

    /// Dragging the selected arrow's body moves both endpoints together; a no-move tap deselects.
    private func arrowMoveDrag(_ spec: AnnotationSpec, mapper: ContentMapper) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragBaseAnnotation == nil { dragBaseAnnotation = spec }
                guard let base = dragBaseAnnotation, base.id == spec.id else { return }
                let d = mapper.normDelta(v.translation)
                let (bp1, bp2) = arrowPoints(base)
                let p1 = CGPoint(x: bp1.x + d.width, y: bp1.y + d.height).clamped01()
                let p2 = CGPoint(x: bp2.x + d.width, y: bp2.y + d.height).clamped01()
                var s = base
                s.arrowStart = p1
                s.arrowEnd = p2
                s.rect = CGRect(corner: p1, opposite: p2)
                model.updateAnnotation(s)
            }
            .onEnded { v in
                dragBaseAnnotation = nil
                if abs(v.translation.width) + abs(v.translation.height) < 3 {
                    model.selectAnnotation(nil)
                }
            }
    }

    /// Dragging an endpoint handle moves just that end; `rect` is recomputed as the bounding box.
    private func arrowEndpointDrag(_ spec: AnnotationSpec, isStart: Bool,
                                   mapper: ContentMapper) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragBaseAnnotation == nil { dragBaseAnnotation = spec }
                guard let base = dragBaseAnnotation, base.id == spec.id else { return }
                let p = mapper.norm(v.location).clamped01()
                let (bp1, bp2) = arrowPoints(base)
                var s = base
                s.arrowStart = isStart ? p : bp1
                s.arrowEnd = isStart ? bp2 : p
                s.rect = CGRect(corner: s.arrowStart!, opposite: s.arrowEnd!)
                model.updateAnnotation(s)
            }
            .onEnded { _ in dragBaseAnnotation = nil }
    }
}

/// Maps content-normalized rects/points (0…1, top-left origin) into the overlay view's
/// coordinates, through the preview's current zoom (a uniform scale about a focus point —
/// applying it in view space is equivalent to the compositor's canvas-space transform). Shared
/// by blur boxes and annotations — same content card, same zoom.
private struct ContentMapper {
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

    /// Content-normalized point → view point (the single-point counterpart of `viewRect`, for
    /// arrow endpoints).
    func viewPoint(_ n: CGPoint) -> CGPoint {
        zoomed(CGPoint(x: contentView.minX + n.x * contentView.width,
                       y: contentView.minY + n.y * contentView.height))
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
private struct RegionHitShape: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}

/// Restricts hit-testing to a thick stroke along the p1–p2 line — an arrow's grabbable body.
private struct LineHitShape: Shape {
    let p1: CGPoint
    let p2: CGPoint
    let width: CGFloat
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: p1)
        p.addLine(to: p2)
        return p.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

private extension StylingModel.AnnotationTool {
    /// `nil` for `.blur`, which isn't an `AnnotationSpec` kind.
    var annotationKind: AnnotationSpec.Kind? {
        switch self {
        case .blur: nil
        case .text: .text
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .spotlight: .spotlight
        }
    }
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
