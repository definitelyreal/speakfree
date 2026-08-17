// ai-suggestion:unverified · session:unknown · 2026-08-16

import Foundation

public enum SwipeCoreError: Error, Equatable {
    case emptyTrajectory
    case invalidKeyboardSize
    case invalidModelOutput(String)
    case invalidDecoderConfiguration(String)
}

public struct TrajectoryPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let timestamp: TimeInterval

    public init(x: Double, y: Double, timestamp: TimeInterval = 0) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }
}

/// Contiguous channel-first model input with shape `[1, 2, sampleCount]`.
public struct SwipeTensor: Equatable, Sendable {
    public let sampleCount: Int
    public let values: [Float]

    public var shape: [Int] { [1, 2, sampleCount] }

    public init(x: [Float], y: [Float]) throws {
        guard !x.isEmpty, x.count == y.count else {
            throw SwipeCoreError.invalidDecoderConfiguration(
                "Swipe tensor channels must be non-empty and equal in length"
            )
        }
        sampleCount = x.count
        values = x + y
    }

    public subscript(channel channel: Int, time time: Int) -> Float {
        values[channel * sampleCount + time]
    }
}

public struct TrajectoryPreprocessor: Sendable {
    public let layout: QWERTYKeyboardLayout
    public let sampleCount: Int

    public init(layout: QWERTYKeyboardLayout = QWERTYKeyboardLayout(), sampleCount: Int = 64) {
        self.layout = layout
        self.sampleCount = sampleCount
    }

    public func prepare(points: [TrajectoryPoint], keyboardSize: KeyboardSize) throws -> SwipeTensor {
        guard !points.isEmpty else { throw SwipeCoreError.emptyTrajectory }
        guard sampleCount > 0 else {
            throw SwipeCoreError.invalidDecoderConfiguration("Sample count must be positive")
        }

        var normalized = try points.map {
            try layout.normalize(x: $0.x, y: $0.y, in: keyboardSize)
        }
        let startTime = points[0].timestamp
        let relativeTimes = points.map { max(0, $0.timestamp - startTime) }
        if let duration = relativeTimes.last, duration > 0, points.count > 1 {
            let sixtyHertzCount = max(2, Int((duration * 60).rounded()) + 1)
            normalized = resampleByTime(
                normalized,
                times: relativeTimes,
                count: sixtyHertzCount,
                duration: duration
            )
        }
        // The published encoder contract performs a uniform 60 Hz interpolation followed by
        // index-based interpolation to the fixed 64 model steps.
        let resampled = resampleByIndex(normalized, count: sampleCount)
        return try SwipeTensor(
            x: resampled.map { Float($0.x) },
            y: resampled.map { Float($0.y) }
        )
    }
}

private func resampleByIndex(_ points: [NormalizedPoint], count: Int) -> [NormalizedPoint] {
    guard count > 1 else { return [points[0]] }
    guard points.count > 1 else { return Array(repeating: points[0], count: count) }
    var result: [NormalizedPoint] = []
    result.reserveCapacity(count)
    for sample in 0..<count {
        let position = Double(sample) * Double(points.count - 1) / Double(count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(points.count - 1, lower + 1)
        result.append(interpolate(points[lower], points[upper], fraction: position - Double(lower)))
    }
    return result
}

private func resampleByTime(
    _ points: [NormalizedPoint],
    times: [TimeInterval],
    count: Int,
    duration: TimeInterval
) -> [NormalizedPoint] {
    var result: [NormalizedPoint] = []
    result.reserveCapacity(count)
    var upper = 1
    for sample in 0..<count {
        let target = duration * Double(sample) / Double(count - 1)
        while upper < times.count - 1, times[upper] < target { upper += 1 }
        let lower = max(0, upper - 1)
        let span = times[upper] - times[lower]
        let fraction = span > 0 ? (target - times[lower]) / span : 0
        result.append(interpolate(points[lower], points[upper], fraction: fraction))
    }
    return result
}

private func interpolate(
    _ start: NormalizedPoint,
    _ end: NormalizedPoint,
    fraction: Double
) -> NormalizedPoint {
    NormalizedPoint(
        x: start.x + (end.x - start.x) * fraction,
        y: start.y + (end.y - start.y) * fraction
    )
}
