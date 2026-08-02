import CoreGraphics
import Foundation
import ProjectStore
import Recording
import RenderCore

/// Loads the recorded `events.jsonl` and maps mouse-down events into the screen's normalized space
/// (top-left origin, 0…1) for auto-zoom. Returns `[]` when the project has no capture rect (window
/// captures, or projects recorded before the capture rect was persisted) or no events file.
enum ClickTrack {
    static func load(package: ProjectPackage) -> [ClickEvent] {
        guard let rect = package.manifest.captureRect, rect.width > 0, rect.height > 0,
              let data = try? Data(contentsOf: package.eventsURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var clicks: [ClickEvent] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let e = try? decoder.decode(LoggedEvent.self, from: lineData),
                  e.type == "down" else { continue }
            let nx = (e.x - rect.minX) / rect.width
            let ny = (e.y - rect.minY) / rect.height
            guard (0...1).contains(nx), (0...1).contains(ny) else { continue } // outside the capture
            clicks.append(ClickEvent(time: e.t, point: CGPoint(x: nx, y: ny)))
        }
        return clicks
    }
}
