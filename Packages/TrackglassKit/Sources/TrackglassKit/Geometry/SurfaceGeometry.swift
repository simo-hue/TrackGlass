public struct SurfacePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct SurfaceSize: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct SurfaceGeometry: Equatable, Sendable {
    public let mmPerPoint: Double
    public let widthMM: Double
    public let heightMM: Double

    public init(ppi: Double, nativeScale: Double, boundsInPoints: SurfaceSize) {
        precondition(ppi.isFinite && ppi > 0 && nativeScale.isFinite && nativeScale > 0)
        precondition(boundsInPoints.width.isFinite && boundsInPoints.width >= 0)
        precondition(boundsInPoints.height.isFinite && boundsInPoints.height >= 0)
        mmPerPoint = (25.4 / ppi) * nativeScale
        widthMM = boundsInPoints.width * mmPerPoint
        heightMM = boundsInPoints.height * mmPerPoint
    }

    /// A size the phone may send in HELLO or SURFACE (C3, L9): both dimensions finite and > 0 as the wire's f32
    /// (§4.5). A zero-size layout pass (scene transition, Stage Manager) is never sent; the last valid one stands.
    public var isValid: Bool {
        let width = Float(widthMM), height = Float(heightMM)
        return width.isFinite && height.isFinite && width > 0 && height > 0
    }

    public func toMM(point: SurfacePoint) -> SurfacePoint {
        SurfacePoint(x: point.x * mmPerPoint, y: point.y * mmPerPoint)
    }
}
