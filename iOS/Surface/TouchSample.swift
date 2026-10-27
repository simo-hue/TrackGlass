import UIKit
import TrackglassKit

/// Converts UIKit's sample values independently of the live touch object's lifetime.
enum TouchSample {
    static func phase(_ phase: UITouch.Phase) -> Contact.Phase? {
        switch phase {
        case .began: .began
        case .moved: .moved
        case .stationary: .stationary
        case .ended: .ended
        case .cancelled: .cancelled
        default: nil
        }
    }

    static func kind(_ type: UITouch.TouchType) -> Contact.Kind? {
        switch type {
        case .direct: .finger
        case .pencil: .stylus
        default: nil
        }
    }

    static func contact(id: UInt8, phase: Contact.Phase, kind: Contact.Kind,
                        location: CGPoint, majorRadius: CGFloat, geometry: SurfaceGeometry) -> Contact {
        let point = geometry.toMM(point: SurfacePoint(x: location.x, y: location.y))
        return Contact(contactID: id, phase: phase, kind: kind, x: Float(point.x), y: Float(point.y),
                       majorRadius: Float(majorRadius * geometry.mmPerPoint))
    }

    static func timestampNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }
}
