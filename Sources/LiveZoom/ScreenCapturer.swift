import CoreMedia
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit and keeps the most recent complete frame.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame {
        let sampleBuffer: CMSampleBuffer
        let sequence: Int
        var surface: IOSurface? {
            CMSampleBufferGetImageBuffer(sampleBuffer).flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
        }
    }

    enum CaptureError: Error {
        case displayNotFound
    }

    /// Our own overlay must never be captured, and OBS hides itself from the stream too.
    static let excludedBundleIDs: Set<String> = ["com.obsproject.obs-studio"]

    var onStop: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.relakkes.livezoom.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: Frame?
    private var sequence = 0
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private(set) var displayID: CGDirectDisplayID?

    var latestFrame: Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    var isRunning: Bool { stream != nil }

    @MainActor
    func start(displayID: CGDirectDisplayID, fps: Int) async throws {
        await stop()
        // Include off-screen windows: our overlay is not visible yet, but the app must be in the list to be excluded.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter {
            $0.processID == pid || Self.excludedBundleIDs.contains($0.bundleIdentifier)
        }
        if !excluded.contains(where: { $0.processID == pid }) {
            log("warning: own app not found in shareable content; the overlay may capture itself")
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(displayID)
        config.width = mode?.pixelWidth ?? display.width * 2
        config.height = mode?.pixelHeight ?? display.height * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.configuration = config
        self.displayID = displayID
    }

    @MainActor
    func setFrameRate(_ fps: Int) async {
        guard let stream, let configuration else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        try? await stream.updateConfiguration(configuration)
    }

    @MainActor
    func stop() async {
        let stream = self.stream
        self.stream = nil
        configuration = nil
        displayID = nil
        lock.withLock { latest = nil }
        try? await stream?.stopCapture()
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { return }
        lock.lock()
        sequence += 1
        latest = Frame(sampleBuffer: sampleBuffer, sequence: sequence)
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.configuration = nil
            self.displayID = nil
            self.onStop?(error)
        }
    }
}
