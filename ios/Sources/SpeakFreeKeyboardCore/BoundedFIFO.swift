// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

/// A small first-in/first-out buffer with explicit backpressure.
///
/// Keyboard extensions have a tight memory budget. Gesture producers must not be able to retain
/// an unlimited number of trajectories while the neural decoder is busy.
public struct BoundedFIFO<Element> {
    public let capacity: Int
    private var storage: [Element] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var first: Element? { storage.first }
    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }

    /// Returns `false` without changing the buffer when it is full.
    @discardableResult
    public mutating func append(_ element: Element) -> Bool {
        guard storage.count < capacity else { return false }
        storage.append(element)
        return true
    }

    @discardableResult
    public mutating func removeFirst() -> Element? {
        guard !storage.isEmpty else { return nil }
        return storage.removeFirst()
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }
}
