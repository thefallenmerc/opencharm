import CoreGraphics
import ScreenCaptureKit

public struct RecordingConfiguration {
    public enum Source {
        case display(CGDirectDisplayID)
        case window(SCWindow)
        /// rect in display points, origin top-left of that display.
        case area(displayID: CGDirectDisplayID, rect: CGRect)
    }

    public var source: Source
    public var webcamDeviceID: String?
    public var micDeviceID: String?
    public var capturesSystemAudio: Bool
    public var fps: Int
    public var excludedWindowNumbers: [Int]

    public init(source: Source, webcamDeviceID: String? = nil, micDeviceID: String? = nil,
                capturesSystemAudio: Bool = true, fps: Int = 60,
                excludedWindowNumbers: [Int] = []) {
        self.source = source
        self.webcamDeviceID = webcamDeviceID
        self.micDeviceID = micDeviceID
        self.capturesSystemAudio = capturesSystemAudio
        self.fps = fps
        self.excludedWindowNumbers = excludedWindowNumbers
    }
}
