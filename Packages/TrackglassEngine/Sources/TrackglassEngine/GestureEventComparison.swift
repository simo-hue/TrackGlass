import Foundation

extension GestureEvent {
    /// Tolerant comparison for fixtures (SPEC §10.1): tags and enum payloads must match exactly,
    /// numeric payloads within `tolerance`. Allocates; for tests and tools only, never the frame path.
    public func approximatelyEquals(_ other: GestureEvent, tolerance: Double = 1e-6) -> Bool {
        guard let lhs = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)),
              let rhs = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(other)) else { return false }
        return Self.approximatelyEqual(lhs, rhs, tolerance: tolerance)
    }

    public static func approximatelyEqual(_ lhs: [GestureEvent], _ rhs: [GestureEvent], tolerance: Double = 1e-6) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices where !lhs[index].approximatelyEquals(rhs[index], tolerance: tolerance) { return false }
        return true
    }

    private static func approximatelyEqual(_ lhs: Any, _ rhs: Any, tolerance: Double) -> Bool {
        switch (lhs, rhs) {
        case let (left as [String: Any], right as [String: Any]):
            guard Set(left.keys) == Set(right.keys) else { return false }
            for (key, value) in left {
                guard let other = right[key], approximatelyEqual(value, other, tolerance: tolerance) else { return false }
            }
            return true
        case let (left as [Any], right as [Any]):
            guard left.count == right.count else { return false }
            for index in left.indices where !approximatelyEqual(left[index], right[index], tolerance: tolerance) { return false }
            return true
        case let (left as NSNumber, right as NSNumber):
            return abs(left.doubleValue - right.doubleValue) <= tolerance
        case let (left as String, right as String):
            return left == right
        default:
            return false
        }
    }
}
