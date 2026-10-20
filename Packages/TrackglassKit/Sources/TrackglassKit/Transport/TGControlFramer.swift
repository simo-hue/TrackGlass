import Foundation
import Network

public final class TGControlFramer: NWProtocolFramerImplementation {
    public static let label = "TGControlFramer"
    public static let definition = NWProtocolFramer.Definition(implementation: TGControlFramer.self)
    public static let maximumMessageLength = 65_536
    private var pendingLength: Int?

    public required init(framer: NWProtocolFramer.Instance) {}
    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }

    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            if pendingLength == nil {
                var length: UInt32?
                let parsed = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, _ in
                    guard let buffer, buffer.count >= 4 else { return 0 }
                    length = UInt32(littleEndian: buffer.loadUnaligned(as: UInt32.self))
                    return 4
                }
                guard parsed, let length else { return 4 }
                guard length >= MessageHeader.byteCount, length <= Self.maximumMessageLength else {
                    framer.markFailed(error: .posix(.EMSGSIZE))
                    return 0
                }
                pendingLength = Int(length)
            }
            guard let length = pendingLength else { return 4 }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            guard framer.deliverInputNoCopy(length: length, message: message, isComplete: true) else {
                return 0
            }
            pendingLength = nil
        }
    }

    public func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                             messageLength: Int, isComplete: Bool) {
        guard isComplete, messageLength >= MessageHeader.byteCount,
              messageLength <= Self.maximumMessageLength else {
            framer.markFailed(error: .posix(.EMSGSIZE))
            return
        }
        var prefix = UInt32(messageLength).littleEndian
        framer.writeOutput(data: withUnsafeBytes(of: &prefix) { Data($0) })
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    public func wakeup(framer: NWProtocolFramer.Instance) {}
    public func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    public func cleanup(framer: NWProtocolFramer.Instance) { pendingLength = nil }
}
