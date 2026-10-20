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

    public func toMM(point: SurfacePoint) -> SurfacePoint {
        SurfacePoint(x: point.x * mmPerPoint, y: point.y * mmPerPoint)
    }
}
