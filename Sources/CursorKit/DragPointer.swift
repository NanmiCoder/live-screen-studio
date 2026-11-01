import CoreGraphics

/// Tracks a swallowed drag without moving the system cursor. Coordinates have a top-left origin.
public struct DragPointer {
    public private(set) var location: CGPoint
    private var previousSample: CGPoint

    public init(at point: CGPoint, bounds: CGRect?) {
        location = Self.confined(point, to: bounds)
        previousSample = point
    }

    public mutating func move(to sample: CGPoint, bounds: CGRect?) {
        // Keep the raw sample even at an edge, so reversing direction moves the pen back immediately.
        let next = CGPoint(x: location.x + (sample.x - previousSample.x),
                           y: location.y + (sample.y - previousSample.y))
        previousSample = sample
        location = Self.confined(next, to: bounds)
    }

    private static func confined(_ point: CGPoint, to bounds: CGRect?) -> CGPoint {
        guard let bounds else { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                       y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}
