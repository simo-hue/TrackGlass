public struct Contact: Equatable, Sendable {
    public enum Phase: UInt8, Sendable { case began = 1, moved, stationary, ended, cancelled }
    public enum Kind: UInt8, Sendable { case finger = 1, stylus }

    public var contactID: UInt8
    public var phase: Phase
    public var kind: Kind
    public var x: Float
    public var y: Float
    public var majorRadius: Float

    public init(contactID: UInt8 = 0, phase: Phase = .stationary, kind: Kind = .finger,
                x: Float = 0, y: Float = 0, majorRadius: Float = 0) {
        self.contactID = contactID
        self.phase = phase
        self.kind = kind
        self.x = x
        self.y = y
        self.majorRadius = majorRadius
    }
}

public struct TouchFrame: Sendable {
    public static let maximumContacts = 10
    public static let maximumByteCount = 188
    public var header: MessageHeader
    public var frameTime: UInt64
    public var surfaceIsLandscape: Bool
    public var isSyntheticLiftoff: Bool
    public private(set) var contactCount = 0
    private var contacts = (Contact(), Contact(), Contact(), Contact(), Contact(),
                            Contact(), Contact(), Contact(), Contact(), Contact())

    public init(sequence: UInt32 = 0, sentAt: UInt64 = 0, frameTime: UInt64 = 0,
                surfaceIsLandscape: Bool = false, isSyntheticLiftoff: Bool = false) {
        header = MessageHeader(type: .touchFrame, sequence: sequence, sentAt: sentAt)
        self.frameTime = frameTime
        self.surfaceIsLandscape = surfaceIsLandscape
        self.isSyntheticLiftoff = isSyntheticLiftoff
    }

    public subscript(index: Int) -> Contact {
        get {
            precondition(index >= 0 && index < contactCount)
            switch index {
            case 0: return contacts.0
            case 1: return contacts.1
            case 2: return contacts.2
            case 3: return contacts.3
            case 4: return contacts.4
            case 5: return contacts.5
            case 6: return contacts.6
            case 7: return contacts.7
            case 8: return contacts.8
            default: return contacts.9
            }
        }
        set {
            precondition(index >= 0 && index < contactCount)
            switch index {
            case 0: contacts.0 = newValue
            case 1: contacts.1 = newValue
            case 2: contacts.2 = newValue
            case 3: contacts.3 = newValue
            case 4: contacts.4 = newValue
            case 5: contacts.5 = newValue
            case 6: contacts.6 = newValue
            case 7: contacts.7 = newValue
            case 8: contacts.8 = newValue
            default: contacts.9 = newValue
            }
        }
    }

    @discardableResult
    public mutating func append(_ contact: Contact) -> Bool {
        guard contactCount < Self.maximumContacts else { return false }
        contactCount += 1
        self[contactCount - 1] = contact
        return true
    }

    public mutating func removeAllContacts() {
        contactCount = 0
    }
}
