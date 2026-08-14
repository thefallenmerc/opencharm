import AVFoundation
import RenderCore
import SwiftUI

/// Screen Charm-style editor strip: transport + time ruler + video track (with trim) + a lane of
/// gold zoom pills. Two clicks in the zoom lane create a manual zoom; pills are selectable,
/// movable, and resizable via their chevron end-caps. (Ported from the original StudioTimeline —
/// the gesture/anchor logic is unchanged; only the styling moved to StudioTheme.)
struct StudioTransport: View {
    @ObservedObject var model: StylingModel

    @State private var timelineZoom: Double = 1        // 1 = fit whole clip to width (100%)
    @State private var pendingStart: Double?           // first click of a two-click zoom
    @State private var selectedID: String?
    @State private var selectedSegmentID: Int?         // selected split segment (delete/restore)
    @State private var drag: ZoomDragAnchor?           // captured at drag start so deltas don't compound

    private let rulerH: CGFloat = 24
    private let trackH: CGFloat = 44
    private let laneH: CGFloat = 38
    private let capW: CGFloat = 16
    private let space = "timeline"

    private var dur: Double { max(model.duration, 0.1) }
    private var trimStart: Double { model.renderSettings.trimStart ?? 0 }
    private var trimEnd: Double { model.renderSettings.trimEnd ?? dur }

    // Track palette (matches the reference).
    private let videoGrad = LinearGradient(
        colors: [Color(.sRGB, red: 0.24, green: 0.34, blue: 0.95, opacity: 1),
                 Color(.sRGB, red: 0.47, green: 0.33, blue: 0.87, opacity: 1)],
        startPoint: .leading, endPoint: .trailing)
    private let videoCap = Color(.sRGB, red: 0.60, green: 0.66, blue: 0.99, opacity: 1)
    private let goldGrad = LinearGradient(
        colors: [Color(.sRGB, red: 1.0, green: 0.80, blue: 0.32, opacity: 1),
                 Color(.sRGB, red: 0.93, green: 0.53, blue: 0.12, opacity: 1)],
        startPoint: .top, endPoint: .bottom)
    private let goldCap = Color(.sRGB, red: 1.0, green: 0.89, blue: 0.58, opacity: 1)
    private let blurGrad = LinearGradient(
        colors: [Color(.sRGB, red: 0.38, green: 0.67, blue: 0.76, opacity: 1),
                 Color(.sRGB, red: 0.15, green: 0.42, blue: 0.55, opacity: 1)],
        startPoint: .top, endPoint: .bottom)
    private let blurCap = Color(.sRGB, red: 0.64, green: 0.85, blue: 0.91, opacity: 1)
    private let playheadColor = Color(.sRGB, red: 0.25, green: 0.55, blue: 1.0, opacity: 1)

    /// Total height of the ruler + lanes stack; the blur lane only appears once boxes exist.
    private var lanesHeight: CGFloat {
        rulerH + trackH + laneH + 16 + (model.blurBoxes.isEmpty ? 0 : laneH + 8)
    }

    var body: some View {
        VStack(spacing: 10) {
            controlRow
            if let id = selectedID, let spec = model.zooms.first(where: { $0.id == id }) {
                zoomEditor(spec)
            }
            if let bid = model.selectedBlurID,
               let spec = model.blurBoxes.first(where: { $0.id == bid }) {
                blurEditor(spec)
            }
            if let sid = selectedSegmentID,
               let seg = model.timelineSegments.first(where: { $0.id == sid }) {
                segmentEditor(seg)
            }
            GeometryReader { geo in
                let pps = (geo.size.width / dur) * timelineZoom
                ScrollView(.horizontal, showsIndicators: timelineZoom > 1.001) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 8) {
                            ruler(pps: pps)
                            track(pps: pps)
                            zoomLane(pps: pps)
                            if !model.blurBoxes.isEmpty {
                                blurLane(pps: pps)
                            }
                        }
                        playhead(pps: pps)
                    }
                    .frame(width: dur * pps, height: lanesHeight, alignment: .topLeading)
                    .coordinateSpace(name: space)
                }
            }
            .frame(height: lanesHeight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(StudioTheme.windowBG)
    }

    // MARK: transport row

    private var controlRow: some View {
        ZStack {
            // Center: time · transport · duration — the focal cluster.
            HStack(spacing: 10) {
                Text(fmt(model.currentTime))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(StudioTheme.textPrimary)
                transport("backward.end.fill") { model.seek(to: trimStart) }
                transport(model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                transport("forward.end.fill") { model.seek(to: trimEnd) }
                Text(fmt(dur))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            HStack(spacing: 14) {
                // Left: timeline zoom.
                HStack(spacing: 8) {
                    Slider(value: $timelineZoom, in: 1...6)
                        .frame(width: 130)
                        .tint(StudioTheme.accent)
                    Text("\(Int(timelineZoom * 100))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StudioTheme.textSecondary)
                    Button {
                        timelineZoom = 1
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .help("Reset timeline zoom")
                    .cursor(.pointingHand)
                }
                Spacer()
                // Right: Blur arms draw-a-privacy-mask mode; Cut splits at the playhead.
                Button {
                    model.isDrawingBlur.toggle()
                } label: {
                    Label("Blur", systemImage: "eye.slash")
                }
                .buttonStyle(ChipButtonStyle(prominent: model.isDrawingBlur))
                .help("Drag on the preview to draw a privacy blur — it appears as a 2s box on the timeline")
                Button {
                    model.splitAtPlayhead()
                } label: {
                    Label("Cut", systemImage: "scissors")
                }
                .buttonStyle(ChipButtonStyle())
                .help("Split at the playhead — select a segment to delete it")
            }
        }
    }

    private func transport(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .frame(width: 44, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(StudioTheme.chipBG))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(StudioTheme.chipBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
    }

    // MARK: selected-zoom editor

    private func zoomEditor(_ spec: ZoomSpec) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%.1f× Zoom", spec.scale))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Slider(value: Binding(get: { spec.scale },
                                  set: { model.setZoomLevel(spec.id, scale: $0) }), in: 1.5...3)
                .frame(width: 160)
                .tint(.orange)
            Text("\(fmt(spec.start))–\(fmt(spec.end))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(StudioTheme.textSecondary)
            Spacer()
            Button(role: .destructive) {
                model.deleteZoom(spec.id)
                selectedID = nil
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(ChipButtonStyle())
        }
        .foregroundStyle(StudioTheme.textPrimary)
    }

    // MARK: ruler

    private func ruler(pps: Double) -> some View {
        Canvas { ctx, size in
            let step = tickStep(pps: pps)
            let minor = step / 5
            func tick(_ t: Double, _ h: CGFloat, _ op: Double) {
                let x = t * pps
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height - h))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(op)), lineWidth: 1)
            }
            var mt = 0.0
            while mt <= dur + 1e-6 { tick(mt, 4, 0.22); mt += minor }
            var Mt = 0.0
            while Mt <= dur + 1e-6 {
                tick(Mt, 9, 0.5)
                ctx.draw(Text(fmt(Mt)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)),
                         at: CGPoint(x: Mt * pps + 3, y: 6), anchor: .leading)
                Mt += step
            }
        }
        .frame(height: rulerH)
        .contentShape(Rectangle())
        .gesture(scrub(pps: pps))
    }

    // MARK: video track + trim + split segments

    private func track(pps: Double) -> some View {
        let x0 = trimStart * pps, x1 = trimEnd * pps
        let segments = model.timelineSegments
        let widestKept = segments.filter { !$0.deleted }
            .max { ($0.end - $0.start) < ($1.end - $1.start) }?.id
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9).fill(videoCap.opacity(0.10)) // track bed
            ForEach(segments) { seg in
                let sx = seg.start * pps
                let w = max(8, (seg.end - seg.start) * pps - 2)
                RoundedRectangle(cornerRadius: 8)
                    .fill(videoGrad)
                    .frame(width: w, height: trackH)
                    .opacity(seg.deleted ? 0.18 : 1)
                    .overlay {
                        if seg.deleted {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        } else if seg.id == widestKept, w > 110 {
                            Label(String(format: "Video: %.1fs", dur), systemImage: "video.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(.white, lineWidth: selectedSegmentID == seg.id ? 2 : 0))
                    .offset(x: sx + 1)
                    .onTapGesture {
                        selectedSegmentID = selectedSegmentID == seg.id ? nil : seg.id
                    }
            }
            endCap(pointsLeft: true, fill: videoCap, height: trackH).offset(x: x0)
                .gesture(edgeDrag(pps) { model.renderSettings.trimStart = min(max(0, $0), trimEnd - 0.1)
                                        model.applyTrim() })
            endCap(pointsLeft: false, fill: videoCap, height: trackH).offset(x: x1 - capW)
                .gesture(edgeDrag(pps) { model.renderSettings.trimEnd = max(min(dur, $0), trimStart + 0.1)
                                        model.applyTrim() })
        }
        .frame(height: trackH)
        .contentShape(Rectangle())
        .gesture(scrub(pps: pps))
    }

    private func segmentEditor(_ seg: StylingModel.TimelineSegment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
            Text("Segment \(fmt(seg.start))–\(fmt(seg.end))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(StudioTheme.textPrimary)
            if seg.deleted {
                Text("deleted — skipped in playback and export")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
            Button {
                model.toggleSegmentDeleted(seg)
            } label: {
                Label(seg.deleted ? "Restore" : "Delete",
                      systemImage: seg.deleted ? "arrow.uturn.backward" : "trash")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    /// The rounded, inset handle at a bar's end — softer than a full-height arrowhead, matching
    /// the reference's pill caps. Hit area spans the full cap width.
    private func endCap(pointsLeft: Bool, fill: Color, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(fill)
                .frame(width: 11, height: height - 8)
            Image(systemName: pointsLeft ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black.opacity(0.4))
        }
        .frame(width: capW, height: height)
        .contentShape(Rectangle())
        .cursor(.resizeLeftRight)
    }

    private func edgeDrag(_ pps: Double, _ set: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { set($0.location.x / pps) }
    }

    // MARK: zoom lane + tags

    private func zoomLane(pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001) // catches two-click creation across the lane
            if let ps = pendingStart {
                Rectangle().fill(Color.orange).frame(width: 2, height: laneH).offset(x: ps * pps)
            }
            ForEach(model.zooms) { spec in zoomTag(spec, pps: pps) }
        }
        .frame(height: laneH)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onEnded { v in
                let t = min(max(0, v.location.x / pps), dur)
                if let start = pendingStart {
                    pendingStart = nil
                    if abs(t - start) > 0.05 { selectedID = model.addZoom(start: start, end: t).id }
                } else {
                    pendingStart = t
                }
            })
    }

    private func zoomTag(_ spec: ZoomSpec, pps: Double) -> some View {
        let x = spec.start * pps
        let w = max(2 * capW + 40, (spec.end - spec.start) * pps)
        let selected = selectedID == spec.id
        let level = spec.scale == spec.scale.rounded()
            ? String(format: "%.0fx Zoom", spec.scale) : String(format: "%.1fx Zoom", spec.scale)
        return ZStack {
            RoundedRectangle(cornerRadius: 9).fill(goldGrad)
            HStack(spacing: 5) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 12, weight: .bold))
                Text(level).font(.system(size: 13, weight: .bold))
                Image(systemName: "computermouse.fill").font(.system(size: 11))
            }
            .foregroundStyle(.black.opacity(0.82))
        }
        .frame(width: w, height: laneH - 2)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white, lineWidth: selected ? 2 : 0))
        .overlay(alignment: .leading) {
            endCap(pointsLeft: true, fill: goldCap, height: laneH - 2)
                .opacity(selected ? 1 : 0.9)
                .gesture(resizeDrag(spec, pps: pps, leading: true))
        }
        .overlay(alignment: .trailing) {
            endCap(pointsLeft: false, fill: goldCap, height: laneH - 2)
                .opacity(selected ? 1 : 0.9)
                .gesture(resizeDrag(spec, pps: pps, leading: false))
        }
        .offset(x: x, y: 1)
        .cursor(.pointingHand)
        .onTapGesture { selectedID = selected ? nil : spec.id }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
            .onChanged { v in
                let a = beginDrag(spec)
                let len = a.end - a.start
                let newStart = min(max(0, a.start + v.translation.width / pps),
                                   max(0, model.duration - len))
                let applied = newStart - a.start
                var s = spec
                s.start = newStart; s.end = newStart + len
                s.focusKeys = a.keys?.map { FocusKey(time: $0.time + applied, point: $0.point) }
                model.updateZoom(s); selectedID = spec.id
            }
            .onEnded { _ in drag = nil })
    }

    /// Dragging a pill's chevron cap changes its start (leading) or end (trailing) — its duration.
    private func resizeDrag(_ spec: ZoomSpec, pps: Double, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { v in
                let a = beginDrag(spec)
                let dt = v.translation.width / pps
                selectedID = spec.id
                if leading { model.resizeZoom(spec, start: a.start + dt) }
                else { model.resizeZoom(spec, end: a.end + dt) }
            }
            .onEnded { _ in drag = nil }
    }

    /// Captures the pill's start/end/keys at the first drag callback so subsequent (translation-based)
    /// callbacks compute an absolute position instead of compounding as the model re-renders mid-drag.
    private func beginDrag(_ spec: ZoomSpec) -> ZoomDragAnchor {
        if let d = drag, d.id == spec.id { return d }
        let d = ZoomDragAnchor(id: spec.id, start: spec.start, end: spec.end, keys: spec.focusKeys)
        drag = d
        return d
    }

    // MARK: blur lane

    private func blurLane(pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9).fill(blurCap.opacity(0.10)) // lane bed
            ForEach(model.blurBoxes) { spec in blurTag(spec, pps: pps) }
        }
        .frame(height: laneH)
        .contentShape(Rectangle())
        .onTapGesture { model.selectBlur(nil) } // empty lane click deselects
    }

    private func blurTag(_ spec: BlurBoxSpec, pps: Double) -> some View {
        let x = spec.start * pps
        let w = max(2 * capW + 30, (spec.end - spec.start) * pps)
        let selected = model.selectedBlurID == spec.id
        return ZStack {
            RoundedRectangle(cornerRadius: 9).fill(blurGrad)
            HStack(spacing: 5) {
                Image(systemName: "eye.slash.fill").font(.system(size: 11, weight: .bold))
                Text("Blur").font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: w, height: laneH - 2)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white, lineWidth: selected ? 2 : 0))
        .overlay(alignment: .leading) {
            endCap(pointsLeft: true, fill: blurCap, height: laneH - 2)
                .opacity(selected ? 1 : 0.9)
                .gesture(blurResizeDrag(spec, pps: pps, leading: true))
        }
        .overlay(alignment: .trailing) {
            endCap(pointsLeft: false, fill: blurCap, height: laneH - 2)
                .opacity(selected ? 1 : 0.9)
                .gesture(blurResizeDrag(spec, pps: pps, leading: false))
        }
        .offset(x: x, y: 1)
        .cursor(.pointingHand)
        .onTapGesture { model.selectBlur(selected ? nil : spec.id) }
        .gesture(blurMoveDrag(spec, pps: pps))
    }

    private func blurEditor(_ spec: BlurBoxSpec) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
            Text("Blur \(fmt(spec.start))–\(fmt(spec.end))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(StudioTheme.textPrimary)
            Text("drag the box on the preview to reposition, corners to resize")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.textSecondary)
            StudioSlider(label: "Corner radius", value: Binding(
                get: { spec.cornerRadius ?? 0.15 },
                set: { model.setBlurStyle(spec.id, cornerRadius: $0) }), range: 0...0.5)
                .frame(width: 130)
            StudioSlider(label: "Intensity", value: Binding(
                get: { spec.intensity ?? 0.5 },
                set: { model.setBlurStyle(spec.id, intensity: $0) }), range: 0...1)
                .frame(width: 130)
            Spacer()
            Button(role: .destructive) {
                model.deleteBlurBox(spec.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(ChipButtonStyle())
        }
        .foregroundStyle(StudioTheme.textPrimary)
    }

    /// Dragging a blur pill moves its whole time span.
    private func blurMoveDrag(_ spec: BlurBoxSpec, pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
            .onChanged { v in
                let a = beginBlurDrag(spec)
                let len = a.end - a.start
                let newStart = min(max(0, a.start + v.translation.width / pps),
                                   max(0, model.duration - len))
                var s = spec
                s.start = newStart
                s.end = newStart + len
                model.updateBlurBox(s)
                model.selectedBlurID = spec.id
            }
            .onEnded { _ in drag = nil }
    }

    /// Dragging a blur pill's chevron cap changes its start (leading) or end (trailing).
    private func blurResizeDrag(_ spec: BlurBoxSpec, pps: Double, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { v in
                let a = beginBlurDrag(spec)
                let dt = v.translation.width / pps
                model.selectedBlurID = spec.id
                if leading { model.resizeBlurBox(spec, start: a.start + dt) }
                else { model.resizeBlurBox(spec, end: a.end + dt) }
            }
            .onEnded { _ in drag = nil }
    }

    /// Same anchor-at-drag-start trick as `beginDrag`, reusing the zoom anchor storage
    /// (ids never collide; only one pill drags at a time).
    private func beginBlurDrag(_ spec: BlurBoxSpec) -> ZoomDragAnchor {
        if let d = drag, d.id == spec.id { return d }
        let d = ZoomDragAnchor(id: spec.id, start: spec.start, end: spec.end, keys: nil)
        drag = d
        return d
    }

    // MARK: playhead

    private func playhead(pps: Double) -> some View {
        let x = model.currentTime * pps
        return Path { p in
            p.move(to: CGPoint(x: x, y: 6))
            p.addLine(to: CGPoint(x: x, y: lanesHeight))
        }
        .stroke(playheadColor, lineWidth: 2)
        .overlay(RoundedRectangle(cornerRadius: 2).fill(playheadColor)
            .frame(width: 10, height: 10).offset(x: x - 5, y: 2), alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: helpers

    private func scrub(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { model.seek(to: $0.location.x / pps) }
    }

    private func tickStep(pps: Double) -> Double {
        let target = 80.0 / pps // aim for a label ~every 80pt
        for s in [0.5, 1, 2, 5, 10, 15, 30, 60] where Double(s) >= target { return Double(s) }
        return 120
    }

    private func fmt(_ s: Double) -> String {
        let v = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", v / 60, v % 60)
    }
}

/// The pill's geometry captured at the start of a move/resize drag.
private struct ZoomDragAnchor {
    let id: String
    let start: Double
    let end: Double
    let keys: [FocusKey]?
}
