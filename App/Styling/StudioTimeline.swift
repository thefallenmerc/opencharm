import AVFoundation
import RenderCore
import SwiftUI

/// Screen Studio-style editor strip: transport + time ruler + video track (with trim) + a lane of
/// yellow zoom tags. Two clicks in the zoom lane create a manual zoom; tags are selectable/editable.
struct StudioTimeline: View {
    @ObservedObject var model: StylingModel

    @State private var timelineZoom: Double = 1        // 1 = fit whole clip to width (100%)
    @State private var pendingStart: Double?           // first click of a two-click zoom
    @State private var selectedID: String?

    private let rulerH: CGFloat = 16
    private let trackH: CGFloat = 30
    private let laneH: CGFloat = 30
    private let space = "timeline"

    private var dur: Double { max(model.duration, 0.1) }
    private var trimStart: Double { model.renderSettings.trimStart ?? 0 }
    private var trimEnd: Double { model.renderSettings.trimEnd ?? dur }

    var body: some View {
        VStack(spacing: 8) {
            controlRow
            if let id = selectedID, let spec = model.zooms.first(where: { $0.id == id }) {
                zoomEditor(spec)
            }
            GeometryReader { geo in
                let pps = (geo.size.width / dur) * timelineZoom
                ScrollView(.horizontal, showsIndicators: timelineZoom > 1.001) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            ruler(pps: pps)
                            track(pps: pps)
                            zoomLane(pps: pps)
                        }
                        playhead(pps: pps)
                    }
                    .frame(width: dur * pps, height: rulerH + trackH + laneH + 8,
                           alignment: .topLeading)
                    .coordinateSpace(name: space)
                }
            }
            .frame(height: rulerH + trackH + laneH + 8)
        }
        .padding(12)
        .background(Color.black.opacity(0.9))
    }

    // MARK: transport row

    private var controlRow: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Slider(value: $timelineZoom, in: 1...6).frame(width: 110)
                Text("\(Int(timelineZoom * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white).frame(width: 42)
                Button { timelineZoom = 1 } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    .help("Reset timeline zoom")
            }
            Spacer()
            HStack(spacing: 14) {
                Text(fmt(model.currentTime)).font(.system(.body, design: .monospaced))
                Button { model.seek(to: trimStart) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(.plain)
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }.buttonStyle(.plain)
                Button { model.seek(to: trimEnd) } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(.plain)
                Text(fmt(dur)).font(.system(.body, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                model.renderSettings.trimEnd = model.currentTime
                model.applyTrim()
            } label: { Label("Cut", systemImage: "scissors") }
                .buttonStyle(.bordered)
                .help("Trim the end at the playhead")
        }
        .foregroundStyle(.white)
    }

    // MARK: selected-zoom editor

    private func zoomEditor(_ spec: ZoomSpec) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%.1f× Zoom", spec.scale)).font(.caption).foregroundStyle(.yellow)
            Slider(value: Binding(get: { spec.scale },
                                  set: { model.setZoomLevel(spec.id, scale: $0) }), in: 1.5...3)
                .frame(width: 160)
            Text("\(fmt(spec.start))–\(fmt(spec.end))").font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Button(role: .destructive) {
                model.deleteZoom(spec.id); selectedID = nil
            } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
    }

    // MARK: ruler

    private func ruler(pps: Double) -> some View {
        Canvas { ctx, size in
            let step = tickStep(pps: pps)
            var t = 0.0
            while t <= dur + 0.001 {
                let x = t * pps
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height - 5)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 1)
                ctx.draw(Text(fmt(t)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: x + 12, y: 5))
                t += step
            }
        }
        .frame(height: rulerH)
        .contentShape(Rectangle())
        .gesture(scrub(pps: pps))
    }

    // MARK: video track + trim

    private func track(pps: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.25)) // full clip (dimmed)
            // kept (trimmed) region
            RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.85))
                .frame(width: max(0, (trimEnd - trimStart) * pps))
                .offset(x: trimStart * pps)
            Text(String(format: "Video: %.1fs", dur)).font(.caption).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            trimHandle(atTime: trimStart, pps: pps) { t in
                model.renderSettings.trimStart = min(max(0, t), trimEnd - 0.1); model.applyTrim()
            }
            trimHandle(atTime: trimEnd, pps: pps) { t in
                model.renderSettings.trimEnd = max(min(dur, t), trimStart + 0.1); model.applyTrim()
            }
        }
        .frame(height: trackH)
        .contentShape(Rectangle())
        .gesture(scrub(pps: pps))
    }

    private func trimHandle(atTime t: Double, pps: Double, set: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.white)
            .frame(width: 6, height: trackH)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.3)))
            .offset(x: t * pps - 3)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { set($0.location.x / pps) })
    }

    // MARK: zoom lane + tags

    private func zoomLane(pps: Double) -> some View {
        ZStack(alignment: .leading) {
            Color.white.opacity(0.001) // catches two-click creation across the lane
            if let ps = pendingStart {
                Rectangle().fill(.yellow).frame(width: 2, height: laneH).offset(x: ps * pps)
            }
            ForEach(model.zooms) { spec in
                zoomTag(spec, pps: pps)
            }
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
        let w = max(24, (spec.end - spec.start) * pps)
        let selected = selectedID == spec.id
        return HStack(spacing: 4) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 10))
            Text(String(format: "%.1f×", spec.scale)).font(.system(size: 11, weight: .semibold))
            Image(systemName: "cursorarrow").font(.system(size: 9))
        }
        .foregroundStyle(.black)
        .frame(width: w, height: laneH - 6)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(.white, lineWidth: selected ? 2 : 0))
        .offset(x: x, y: 3)
        .onTapGesture { selectedID = selected ? nil : spec.id }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
            .onChanged { v in
                model.shiftZoom(spec, by: v.translation.width / pps)
                selectedID = spec.id
            })
    }

    // MARK: playhead

    private func playhead(pps: Double) -> some View {
        let x = model.currentTime * pps
        return Path { p in
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: rulerH + trackH + laneH + 8))
        }
        .stroke(Color.red, lineWidth: 1.5)
        .overlay(Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: x - 4, y: -1),
                 alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: helpers

    private func scrub(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { model.seek(to: $0.location.x / pps) }
    }

    private func tickStep(pps: Double) -> Double {
        // aim for a label ~every 70pt
        let target = 70.0 / pps
        for s in [0.5, 1, 2, 5, 10, 15, 30, 60] where Double(s) >= target { return Double(s) }
        return 120
    }

    private func fmt(_ s: Double) -> String {
        let v = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", v / 60, v % 60)
    }
}
