// ai-suggestion:unverified · session:unknown · 2026-08-16

import Foundation

public struct KeyboardSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct NormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct KeyboardKey: Equatable, Sendable {
    public let character: Character
    public let center: NormalizedPoint

    public init(character: Character, center: NormalizedPoint) {
        self.character = character
        self.center = center
    }
}

/// A layout description in a device-independent, zero-to-one coordinate space.
public struct QWERTYKeyboardLayout: Equatable, Sendable {
    public let keys: [KeyboardKey]

    public init(keys: [KeyboardKey] = QWERTYKeyboardLayout.standardKeys) {
        self.keys = keys
    }

    public func normalize(x: Double, y: Double, in size: KeyboardSize) throws -> NormalizedPoint {
        guard size.width > 0, size.height > 0 else {
            throw SwipeCoreError.invalidKeyboardSize
        }
        return NormalizedPoint(
            x: min(1, max(0, x / size.width)),
            y: min(1, max(0, y / size.height))
        )
    }

    public func closestKey(to point: NormalizedPoint) -> KeyboardKey? {
        keys.min { lhs, rhs in
            squaredDistance(lhs.center, point) < squaredDistance(rhs.center, point)
        }
    }

    public static let standardKeys: [KeyboardKey] = {
        // Horizontal offsets approximate the stagger of the three alphabet rows.
        let rows: [(characters: String, offset: Double)] = [
            ("qwertyuiop", 0),
            ("asdfghjkl", 0.5),
            ("zxcvbnm", 1.5),
        ]
        let widestRowUnits = 10.0
        return rows.enumerated().flatMap { rowIndex, row in
            row.characters.enumerated().map { columnIndex, character in
                KeyboardKey(
                    character: character,
                    center: NormalizedPoint(
                        x: (row.offset + Double(columnIndex) + 0.5) / widestRowUnits,
                        y: (Double(rowIndex) + 0.5) / Double(rows.count)
                    )
                )
            }
        }
    }()
}

private func squaredDistance(_ lhs: NormalizedPoint, _ rhs: NormalizedPoint) -> Double {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return dx * dx + dy * dy
}
