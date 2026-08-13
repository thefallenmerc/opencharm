import CoreGraphics
import Foundation
import ProjectStore
import Recording
import RenderCore

/// Loads the recorded `events.jsonl` and maps pointer events into the capture's normalized space
/// (top-left origin, 0…1) for auto-zoom and the synthetic cursor. The capture rect starts from the
/// manifest's `captureRect` and follows any "rect" events in the log (written when a captured
/// window moves or resizes), so clicks map through the frame that was current when they happened.
/// Returns `[]` for projects with no rect information at all (recorded before rects were persisted).
enum ClickTrack {
    private static func parsedEvents(package: ProjectPackage) -> [LoggedEvent] {
        guard let data = try? Data(contentsOf: package.eventsURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var events: [LoggedEvent] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let e = try? decoder.decode(LoggedEvent.self, from: lineData) else { continue }
            events.append(e)
        }
        return events
    }

    static func load(package: ProjectPackage) -> [ClickEvent] {
        CaptureSpace.normalize(events: parsedEvents(package: package),
                               initial: package.manifest.captureRect)
            .filter { $0.event.type == "down" }
            .map { ClickEvent(time: $0.event.t, point: $0.point) }
    }

    /// All pointer samples (moves + clicks) in normalized screen space, time-ordered — used to
    /// focus zooms on the cursor, drive the cursor-follow pan, and draw the synthetic pointer
    /// (with its recorded shape, when the log captured one).
    static func loadCursor(package: ProjectPackage) -> [CursorSample] {
        CaptureSpace.normalize(events: parsedEvents(package: package),
                               initial: package.manifest.captureRect)
            .map { CursorSample(time: $0.event.t, point: $0.point,
                                cursorType: $0.event.cursorType) }
    }
}
