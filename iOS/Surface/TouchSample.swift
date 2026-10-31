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

/// The slice of `UITouch` the surface reads. `UITouch` conforms as-is (same selectors); tests drive the
/// pipeline with fakes. `@objc` so that `any TouchLike` is a class reference the contact table can hold,
/// `@MainActor` because UIKit's touch properties are main-actor-isolated.
@MainActor @objc protocol TouchLike: AnyObject {
    var phase: UITouch.Phase { get }
    var type: UITouch.TouchType { get }
    var majorRadius: CGFloat { get }
    @objc(preciseLocationInView:) func preciseLocation(in view: UIView?) -> CGPoint
}

extension UITouch: TouchLike {}

/// A coalesced sample (`UIEvent.coalescedTouches(for:)`): the touch's values at one digitizer scan, plus its time.
@MainActor @objc protocol TouchSampleLike: TouchLike {
    var timestamp: TimeInterval { get }
}

extension UITouch: TouchSampleLike {}
