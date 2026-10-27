import Foundation

public enum ButtonKind: String, Codable, Sendable { case left, right }
public enum ButtonPhase: String, Codable, Sendable { case down, up }
public enum GesturePhase: String, Codable, Sendable { case mayBegin, began, changed, ended, cancelled }
public enum MomentumPhase: String, Codable, Sendable { case begin, continued, end }
public enum DockSwipeKind: String, Codable, Sendable { case horizontal, vertical, pinch }
public enum SwipeDirection: String, Codable, Sendable { case left, right, up, down }
public enum HapticKind: String, Codable, Sendable { case click, secondaryClick, forceClickStage2, dragLockEngaged, dragLockReleased, spaceSwitched }

public struct TrackpadSettings: Codable, Sendable, Equatable {
    public var naturalScrolling: Bool
    public var clicking: Bool
    public var trackpadRightClick: Bool
    public var cornerSecondaryClick: Int
    public var dragging: Bool
    public var dragLock: Bool
    public var threeFingerDrag: Bool
    public var forceClickEnabled: Bool
    public var threeFingerTapGesture: Int
    public var trackingSpeed: Double
    public var scrollEnabled: Bool
    public var horizontalScrollEnabled: Bool
    public var momentumScrollEnabled: Bool
    public var pinchEnabled: Bool
    public var rotateEnabled: Bool
    public var smartZoomEnabled: Bool
    public var swipeNavigationEnabled: Bool
    public var threeFingerHorizontalGesture: Int
    public var fourFingerHorizontalGesture: Int
    public var threeFingerVerticalGesture: Int
    public var fourFingerVerticalGesture: Int
    public var fourFingerPinchGesture: Int
    public var fiveFingerPinchGesture: Int
    public var notificationCenterEdgeGesture: Int
    public var missionControlEnabled: Bool
    public var appExposeEnabled: Bool
    public var launchpadEnabled: Bool
    public var showDesktopEnabled: Bool
    public var doubleClickIntervalNs: UInt64

    public init(naturalScrolling: Bool = true, clicking: Bool = true, trackpadRightClick: Bool = true, cornerSecondaryClick: Int = 0,
                dragging: Bool = false, dragLock: Bool = false, threeFingerDrag: Bool = false,
                forceClickEnabled: Bool = true, threeFingerTapGesture: Int = 2, trackingSpeed: Double = 0.6875,
                scrollEnabled: Bool = true, horizontalScrollEnabled: Bool = true, momentumScrollEnabled: Bool = true, pinchEnabled: Bool = true, rotateEnabled: Bool = true, smartZoomEnabled: Bool = true, swipeNavigationEnabled: Bool = true,
                threeFingerHorizontalGesture: Int = 2,
                fourFingerHorizontalGesture: Int = 2,
                threeFingerVerticalGesture: Int = 2,
                fourFingerVerticalGesture: Int = 2,
                fourFingerPinchGesture: Int = 2,
                fiveFingerPinchGesture: Int = 2,
                notificationCenterEdgeGesture: Int = 3,
                missionControlEnabled: Bool = true,
                appExposeEnabled: Bool = true,
                launchpadEnabled: Bool = true,
                showDesktopEnabled: Bool = true,
                doubleClickIntervalNs: UInt64 = 500_000_000) {
        self.naturalScrolling = naturalScrolling; self.clicking = clicking; self.trackpadRightClick = trackpadRightClick
        self.cornerSecondaryClick = cornerSecondaryClick; self.dragging = dragging
        self.dragLock = dragLock; self.threeFingerDrag = threeFingerDrag
        self.forceClickEnabled = forceClickEnabled; self.threeFingerTapGesture = threeFingerTapGesture
        self.scrollEnabled = scrollEnabled
        self.horizontalScrollEnabled = horizontalScrollEnabled
        self.momentumScrollEnabled = momentumScrollEnabled
        self.pinchEnabled = pinchEnabled
        self.rotateEnabled = rotateEnabled
        self.smartZoomEnabled = smartZoomEnabled
        self.swipeNavigationEnabled = swipeNavigationEnabled
        self.threeFingerHorizontalGesture = threeFingerHorizontalGesture
        self.fourFingerHorizontalGesture = fourFingerHorizontalGesture
        self.threeFingerVerticalGesture = threeFingerVerticalGesture
        self.fourFingerVerticalGesture = fourFingerVerticalGesture
        self.fourFingerPinchGesture = fourFingerPinchGesture
        self.fiveFingerPinchGesture = fiveFingerPinchGesture
        self.notificationCenterEdgeGesture = notificationCenterEdgeGesture
        self.missionControlEnabled = missionControlEnabled
        self.appExposeEnabled = appExposeEnabled
        self.launchpadEnabled = launchpadEnabled
        self.showDesktopEnabled = showDesktopEnabled
        self.trackingSpeed = trackingSpeed; self.doubleClickIntervalNs = doubleClickIntervalNs
    }

    private enum CodingKeys: String, CodingKey { case naturalScrolling, clicking, trackpadRightClick, cornerSecondaryClick, dragging, dragLock, threeFingerDrag, forceClickEnabled, threeFingerTapGesture, trackingSpeed, doubleClickIntervalNs, scrollEnabled, horizontalScrollEnabled, momentumScrollEnabled, pinchEnabled, rotateEnabled, smartZoomEnabled, swipeNavigationEnabled, threeFingerHorizontalGesture, fourFingerHorizontalGesture, threeFingerVerticalGesture, fourFingerVerticalGesture, fourFingerPinchGesture, fiveFingerPinchGesture, notificationCenterEdgeGesture, missionControlEnabled, appExposeEnabled, launchpadEnabled, showDesktopEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        naturalScrolling = try values.decodeIfPresent(Bool.self, forKey: .naturalScrolling) ?? true
        clicking = try values.decodeIfPresent(Bool.self, forKey: .clicking) ?? true
        trackpadRightClick = try values.decodeIfPresent(Bool.self, forKey: .trackpadRightClick) ?? true
        cornerSecondaryClick = try values.decodeIfPresent(Int.self, forKey: .cornerSecondaryClick) ?? 0
        dragging = try values.decodeIfPresent(Bool.self, forKey: .dragging) ?? false
        dragLock = try values.decodeIfPresent(Bool.self, forKey: .dragLock) ?? false
        threeFingerDrag = try values.decodeIfPresent(Bool.self, forKey: .threeFingerDrag) ?? false
        forceClickEnabled = try values.decodeIfPresent(Bool.self, forKey: .forceClickEnabled) ?? true
        threeFingerTapGesture = try values.decodeIfPresent(Int.self, forKey: .threeFingerTapGesture) ?? 2
        trackingSpeed = try values.decodeIfPresent(Double.self, forKey: .trackingSpeed) ?? 0.6875
        scrollEnabled = try values.decodeIfPresent(Bool.self, forKey: .scrollEnabled) ?? true
        horizontalScrollEnabled = try values.decodeIfPresent(Bool.self, forKey: .horizontalScrollEnabled) ?? true
        momentumScrollEnabled = try values.decodeIfPresent(Bool.self, forKey: .momentumScrollEnabled) ?? true
        pinchEnabled = try values.decodeIfPresent(Bool.self, forKey: .pinchEnabled) ?? true
        rotateEnabled = try values.decodeIfPresent(Bool.self, forKey: .rotateEnabled) ?? true
        smartZoomEnabled = try values.decodeIfPresent(Bool.self, forKey: .smartZoomEnabled) ?? true
        swipeNavigationEnabled = try values.decodeIfPresent(Bool.self, forKey: .swipeNavigationEnabled) ?? true
        threeFingerHorizontalGesture = try values.decodeIfPresent(Int.self, forKey: .threeFingerHorizontalGesture) ?? 2
        fourFingerHorizontalGesture = try values.decodeIfPresent(Int.self, forKey: .fourFingerHorizontalGesture) ?? 2
        threeFingerVerticalGesture = try values.decodeIfPresent(Int.self, forKey: .threeFingerVerticalGesture) ?? 2
        fourFingerVerticalGesture = try values.decodeIfPresent(Int.self, forKey: .fourFingerVerticalGesture) ?? 2
        fourFingerPinchGesture = try values.decodeIfPresent(Int.self, forKey: .fourFingerPinchGesture) ?? 2
        fiveFingerPinchGesture = try values.decodeIfPresent(Int.self, forKey: .fiveFingerPinchGesture) ?? 2
        notificationCenterEdgeGesture = try values.decodeIfPresent(Int.self, forKey: .notificationCenterEdgeGesture) ?? 3
        missionControlEnabled = try values.decodeIfPresent(Bool.self, forKey: .missionControlEnabled) ?? true
        appExposeEnabled = try values.decodeIfPresent(Bool.self, forKey: .appExposeEnabled) ?? true
        launchpadEnabled = try values.decodeIfPresent(Bool.self, forKey: .launchpadEnabled) ?? true
        showDesktopEnabled = try values.decodeIfPresent(Bool.self, forKey: .showDesktopEnabled) ?? true
        doubleClickIntervalNs = try values.decodeIfPresent(UInt64.self, forKey: .doubleClickIntervalNs) ?? 500_000_000
    }
}

public enum GestureEvent: Codable, Equatable, Sendable {
    case pointerMove(dx: Double, dy: Double)
    case button(kind: ButtonKind, phase: ButtonPhase, clickCount: Int)
    case scroll(dxPoints: Double, dyPoints: Double, phase: GesturePhase, naturalInverted: Bool)
    case scrollMomentum(phase: MomentumPhase, dxPoints: Double, dyPoints: Double)
    case magnify(delta: Double, phase: GesturePhase)
    case rotate(deltaDegrees: Double, phase: GesturePhase)
    case smartZoom
    case dockSwipe(kind: DockSwipeKind, progressDelta: Double, phase: GesturePhase, exitVelocity: Double)
    case navigationSwipe(direction: SwipeDirection)
    case notificationCenter
    case forceClick(stage: Int)
    case lookUpAtPointer
    case haptic(HapticKind)
    case gestureBegin
    case gestureEnd

    private enum Key: String, CodingKey { case t, dx, dy, kind, phase, clickCount, dxPoints, dyPoints, naturalInverted, delta, deltaDegrees, progressDelta, exitVelocity, direction, stage }
    private enum Tag: String, Codable { case pointerMove, button, scroll, scrollMomentum, magnify, rotate, smartZoom, dockSwipe, navigationSwipe, notificationCenter, forceClick, lookUpAtPointer, haptic, gestureBegin, gestureEnd }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .pointerMove: self = .pointerMove(dx: try c.decode(Double.self, forKey: .dx), dy: try c.decode(Double.self, forKey: .dy))
        case .button: self = .button(kind: try c.decode(ButtonKind.self, forKey: .kind), phase: try c.decode(ButtonPhase.self, forKey: .phase), clickCount: try c.decode(Int.self, forKey: .clickCount))
        case .scroll: self = .scroll(dxPoints: try c.decode(Double.self, forKey: .dxPoints), dyPoints: try c.decode(Double.self, forKey: .dyPoints), phase: try c.decode(GesturePhase.self, forKey: .phase), naturalInverted: try c.decode(Bool.self, forKey: .naturalInverted))
        case .scrollMomentum: self = .scrollMomentum(phase: try c.decode(MomentumPhase.self, forKey: .phase), dxPoints: try c.decode(Double.self, forKey: .dxPoints), dyPoints: try c.decode(Double.self, forKey: .dyPoints))
        case .magnify: self = .magnify(delta: try c.decode(Double.self, forKey: .delta), phase: try c.decode(GesturePhase.self, forKey: .phase))
        case .rotate: self = .rotate(deltaDegrees: try c.decode(Double.self, forKey: .deltaDegrees), phase: try c.decode(GesturePhase.self, forKey: .phase))
        case .smartZoom: self = .smartZoom
        case .dockSwipe: self = .dockSwipe(kind: try c.decode(DockSwipeKind.self, forKey: .kind), progressDelta: try c.decode(Double.self, forKey: .progressDelta), phase: try c.decode(GesturePhase.self, forKey: .phase), exitVelocity: try c.decode(Double.self, forKey: .exitVelocity))
        case .navigationSwipe: self = .navigationSwipe(direction: try c.decode(SwipeDirection.self, forKey: .direction))
        case .notificationCenter: self = .notificationCenter
        case .forceClick: self = .forceClick(stage: try c.decode(Int.self, forKey: .stage))
        case .lookUpAtPointer: self = .lookUpAtPointer
        case .haptic: self = .haptic(try c.decode(HapticKind.self, forKey: .kind))
        case .gestureBegin: self = .gestureBegin
        case .gestureEnd: self = .gestureEnd
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .pointerMove(dx, dy): try c.encode(Tag.pointerMove, forKey: .t); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case let .button(kind, phase, count): try c.encode(Tag.button, forKey: .t); try c.encode(kind, forKey: .kind); try c.encode(phase, forKey: .phase); try c.encode(count, forKey: .clickCount)
        case let .scroll(dx, dy, phase, natural): try c.encode(Tag.scroll, forKey: .t); try c.encode(dx, forKey: .dxPoints); try c.encode(dy, forKey: .dyPoints); try c.encode(phase, forKey: .phase); try c.encode(natural, forKey: .naturalInverted)
        case let .scrollMomentum(phase, dx, dy): try c.encode(Tag.scrollMomentum, forKey: .t); try c.encode(phase, forKey: .phase); try c.encode(dx, forKey: .dxPoints); try c.encode(dy, forKey: .dyPoints)
        case let .magnify(delta, phase): try c.encode(Tag.magnify, forKey: .t); try c.encode(delta, forKey: .delta); try c.encode(phase, forKey: .phase)
        case let .rotate(delta, phase): try c.encode(Tag.rotate, forKey: .t); try c.encode(delta, forKey: .deltaDegrees); try c.encode(phase, forKey: .phase)
        case .smartZoom: try c.encode(Tag.smartZoom, forKey: .t)
        case let .dockSwipe(kind, delta, phase, velocity): try c.encode(Tag.dockSwipe, forKey: .t); try c.encode(kind, forKey: .kind); try c.encode(delta, forKey: .progressDelta); try c.encode(phase, forKey: .phase); try c.encode(velocity, forKey: .exitVelocity)
        case let .navigationSwipe(direction): try c.encode(Tag.navigationSwipe, forKey: .t); try c.encode(direction, forKey: .direction)
        case .notificationCenter: try c.encode(Tag.notificationCenter, forKey: .t)
        case let .forceClick(stage): try c.encode(Tag.forceClick, forKey: .t); try c.encode(stage, forKey: .stage)
        case .lookUpAtPointer: try c.encode(Tag.lookUpAtPointer, forKey: .t)
        case let .haptic(kind): try c.encode(Tag.haptic, forKey: .t); try c.encode(kind, forKey: .kind)
        case .gestureBegin: try c.encode(Tag.gestureBegin, forKey: .t)
        case .gestureEnd: try c.encode(Tag.gestureEnd, forKey: .t)
        }
    }
}
