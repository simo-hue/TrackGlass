import UIKit
import OSLog

@MainActor
final class DisplayLinkDriver {
    var onTick: (() -> Void)?
    private var link: CADisplayLink?
    private let target = DisplayLinkTarget()
    private var movedEvents = 0
    private var sampleStart: CFTimeInterval = 0
    private let logger = Logger(subsystem: "app.trackglass.ios", category: "TouchRate")

    func start(screen: UIScreen) {
        guard link == nil else { return }
        target.driver = self
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        if screen.maximumFramesPerSecond > 60 {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        sampleStart = CACurrentMediaTime()
        movedEvents = 0
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        movedEvents = 0
    }

    func recordMovedEvent() { movedEvents += 1 }

    fileprivate func tick(_ link: CADisplayLink) {
        onTick?()
        let elapsed = link.timestamp - sampleStart
        guard elapsed >= 1 else { return }
        let rate = Double(movedEvents) / elapsed
        logger.debug("touchesMoved events/s=\(rate, privacy: .public)")
        movedEvents = 0
        sampleStart = link.timestamp
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var driver: DisplayLinkDriver?

    @objc func tick(_ link: CADisplayLink) {
        guard let driver else {
            link.invalidate()
            return
        }
        driver.tick(link)
    }
}
