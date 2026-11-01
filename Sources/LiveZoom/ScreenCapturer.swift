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
    /// Frames are accepted only from this stream (guarded by `lock`, read on the capture queue).
    private var acceptedStream: ObjectIdentifier?
    private var configuration: SCStreamConfiguration?
    /// Bumped by every start, stop and cancel. A start that finds it changed after an await was superseded:
    /// it shuts its own stream down instead of leaving a second capture running.
    private var generation = 0
    private(set) var displayID: CGDirectDisplayID?

    var latestFrame: Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    var isRunning: Bool { stream != nil }

    /// Throws `CancellationError` if `stop()`, `cancelPendingStart()` or another `start` came first.
    @MainActor
    func start(displayID: CGDirectDisplayID, fps: Int) async throws {
        generation += 1
        let mine = generation
        await stopStream()
        // Include off-screen windows: our overlay is not visible yet, but the app must be in the list to be excluded.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard mine == generation else { throw CancellationError() }
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
        config.minimumFrameInterval = Self.interval(fps: fps)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        // Accept its frames before it starts: with a static screen the first frame may be the only complete one.
        let id = ObjectIdentifier(stream)
        lock.withLock { acceptedStream = id }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock { if acceptedStream == id { acceptedStream = nil } }
            throw error
        }
        guard mine == generation else {
            lock.withLock { if acceptedStream == id { acceptedStream = nil } }
            try? await stream.stopCapture()
            throw CancellationError()
        }
        self.stream = stream
        self.configuration = config
        self.displayID = displayID
    }

    /// Abandons a start that is still in progress; a stream that is already running is left alone.
    @MainActor
    func cancelPendingStart() {
        generation += 1
    }

    @MainActor
    func setFrameRate(_ fps: Int) async {
        guard let stream, let configuration else { return }
        configuration.minimumFrameInterval = Self.interval(fps: fps)
        try? await stream.updateConfiguration(configuration)
    }

    /// An interval exactly equal to the refresh period makes ScreenCaptureKit drop frames that arrive a hair early,
    /// so ask for 90% of it (as OBS does).
    private static func interval(fps: Int) -> CMTime {
        CMTime(seconds: 0.9 / Double(max(fps, 1)), preferredTimescale: 600_000)
    }

    /// The display's refresh rate, 60 when unknown.
    static func refreshRate(of displayID: CGDirectDisplayID) -> Int {
        let rate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        return rate > 0 ? Int(rate.rounded()) : 60
    }

    @MainActor
    func stop() async {
        generation += 1
        await stopStream()
    }

    @MainActor
    private func stopStream() async {
        let stream = self.stream
        self.stream = nil
        configuration = nil
        displayID = nil
        lock.withLock {
            latest = nil
            acceptedStream = nil
        }
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
        lock.withLock {
            guard acceptedStream == ObjectIdentifier(stream) else { return }
            sequence += 1
            latest = Frame(sampleBuffer: sampleBuffer, sequence: sequence)
        }
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
