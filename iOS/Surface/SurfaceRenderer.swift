import UIKit
import TrackglassKit

@MainActor
final class SurfaceRenderer {
    private let background = CAGradientLayer()
    private let noise = CALayer()
    private let grid = CAShapeLayer()
    private let halos = (0..<10).map { _ in CAGradientLayer() }
    private var identifiers = [UInt8?](repeating: nil, count: 10)
    private var seen = [Bool](repeating: false, count: 10)
    private var theme = Theme.preset(.glassBlack)
    /// SPEC §5.9: thermal state `.serious` or worse renders no halos; touch delivery is unaffected.
    private(set) var halosSuppressed = false
    private static let noiseTile: UIImage? = {
        var bytes = [UInt8](repeating: 0, count: 64 * 64)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 64,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }()
    init(layer: CALayer) {
        layer.addSublayer(background); background.addSublayer(noise); layer.addSublayer(grid)
        for halo in halos {
            halo.type = .radial
            halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
            halo.bounds = CGRect(x: 0, y: 0, width: 88, height: 88)
            halo.opacity = 0
            layer.addSublayer(halo)
        }
        if let tile = Self.noiseTile { noise.backgroundColor = UIColor(patternImage: tile).cgColor }
        noise.opacity = 0.06
        apply(theme)
    }
    func apply(_ theme: Theme) {
        self.theme = theme
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if theme.background == .aluminum {
            background.colors = [0xD9D9DE, 0xBFBFC4, 0xD4D4D9].map { Theme.color(UInt32($0)).cgColor }
        } else { background.colors = [Theme.color(theme.backgroundRGB).cgColor, Theme.color(theme.backgroundRGB).cgColor] }
        background.cornerRadius = theme.background == .aluminum ? 12 : 0
        background.masksToBounds = true
        noise.isHidden = theme.background != .aluminum
        grid.isHidden = !theme.showsGrid
        grid.fillColor = Theme.color(theme.accentRGB).withAlphaComponent(0.08).cgColor
        let color = theme.fingerGlow == .dark ? UIColor.black : Theme.color(theme.accentRGB)
        for halo in halos { halo.colors = [color.withAlphaComponent(CGFloat(theme.glowOpacity)).cgColor, color.withAlphaComponent(0).cgColor] }
        CATransaction.commit()
    }
    func layout(bounds: CGRect, mmPerPoint: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        background.frame = theme.background == .aluminum ? bounds.insetBy(dx: 8, dy: 8) : bounds
        noise.frame = background.bounds
        grid.frame = bounds
        let path = CGMutablePath()
        let spacing = 10 / max(mmPerPoint, 0.01)
        var y = spacing / 2
        while y < bounds.height {
            var x = spacing / 2
            while x < bounds.width {
                path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)); x += spacing
            }
            y += spacing
        }
        grid.path = path
        CATransaction.commit()
    }
    func setHalosSuppressed(_ suppressed: Bool) {
        guard suppressed != halosSuppressed else { return }
        halosSuppressed = suppressed
        guard suppressed else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for index in identifiers.indices {
            identifiers[index] = nil
            halos[index].removeAnimation(forKey: "opacity")
            halos[index].opacity = 0
        }
        CATransaction.commit()
    }
    func render(_ frame: TouchFrame, mmPerPoint: Double) {
        for index in seen.indices { seen[index] = false }
        if theme.fingerGlow != .none && !halosSuppressed {
            for index in 0..<frame.contactCount {
                let contact = frame[index]
                guard contact.kind == .finger, contact.phase != .ended, contact.phase != .cancelled else { continue }
                guard let slot = identifiers.firstIndex(where: { $0 == contact.contactID }) ?? identifiers.firstIndex(where: { $0 == nil }) else { continue }
                if identifiers[slot] == nil { halos[slot].removeAnimation(forKey: "opacity") }
                identifiers[slot] = contact.contactID; seen[slot] = true
                CATransaction.begin(); CATransaction.setDisableActions(true)
                halos[slot].position = CGPoint(x: Double(contact.x) / mmPerPoint, y: Double(contact.y) / mmPerPoint)
                halos[slot].opacity = 1
                CATransaction.commit()
            }
        }
        for index in seen.indices where !seen[index] && identifiers[index] != nil {
            identifiers[index] = nil
            CATransaction.begin(); CATransaction.setAnimationDuration(0.22)
            halos[index].opacity = 0
            CATransaction.commit()
        }
    }
}
