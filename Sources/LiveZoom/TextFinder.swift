import CoreMedia
import CoreVideo
import CursorKit
import Foundation
import QuartzCore
import Vision

/// Finds the line of text under the cursor in a captured frame, so a shortcut can mark exactly that line.
enum TextFinder {
    private static let queue = DispatchQueue(label: "com.relakkes.livezoom.text", qos: .userInitiated)
    /// Only rows this far above and below the cursor are read, to keep the lookup quick.
    private static let band: CGFloat = 60
    private static var warmedUp = false

    /// - Parameters:
    ///   - frame: The captured display; it stays alive until the lookup is done.
    ///   - cursor: Display-local content point, top-left origin.
    ///   - visible: The part of the display on screen while zoomed, in the same coordinates. Text is read across
    ///     it plus a margin on either side, not across the whole display, which takes about twice as long.
    ///   - display: Display size in points.
    ///   - completion: On the main thread, with the line in display-local content points, or nil.
    static func line(in frame: ScreenCapturer.Frame, at cursor: CGPoint, visible: CGRect, display: CGSize,
                     completion: @escaping (CGRect?) -> Void) {
        guard let buffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else { return completion(nil) }
        let top = max(cursor.y - band, 0), bottom = min(cursor.y + band, display.height)
        let left = max(visible.minX - visible.width * 0.25, 0)
        let right = min(visible.maxX + visible.width * 0.25, display.width)
        guard bottom > top, right > left else { return completion(nil) }
        let area = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        queue.async {
            let request = makeRequest()
            // Normalized, bottom-left origin; results come back relative to this area.
            request.regionOfInterest = CGRect(x: area.minX / display.width, y: 1 - area.maxY / display.height,
                                              width: area.width / display.width, height: area.height / display.height)
            let started = CACurrentMediaTime()
            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
            } catch {
                log("text lookup failed: \(error.localizedDescription)")
            }
            let segments = (request.results ?? []).map { found -> CGRect in
                let box = found.boundingBox
                return CGRect(x: area.minX + box.minX * area.width, y: area.minY + (1 - box.maxY) * area.height,
                              width: box.width * area.width, height: box.height * area.height)
            }
            let line = TextLines.line(at: cursor, in: segments)
            withExtendedLifetime(frame) {}
            log(String(format: "text lookup: %d segments, %@ in %.0f ms", segments.count,
                       line == nil ? "no line" : "found a line", (CACurrentMediaTime() - started) * 1000))
            DispatchQueue.main.async { completion(line) }
        }
    }

    /// Loads the recognizer ahead of the first lookup, which would otherwise take about a third of a second longer.
    static func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        queue.async {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return }
            try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([makeRequest()])
        }
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        // The fast recognizer misses Chinese; the accurate one finds whole lines in both.
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        return request
    }
}
