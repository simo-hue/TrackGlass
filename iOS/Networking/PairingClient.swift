import CryptoKit
import Foundation
import Network
import TrackglassKit

@MainActor
final class PairingClient {
    enum Failure: Error, LocalizedError {
        case invalidResponse, expired, network(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The Mac returned an invalid pairing response."
            case .expired: "Pairing expired. Open a new pairing window and scan again."
            case .network(let message): "Pairing connection failed: \(message)"
            }
        }
    }

    private let store: PairingStore
    private var connection: NWConnection?
    private var completion: CheckedContinuation<PairedPeer, Error>?
    private var timeout: Task<Void, Never>?
    private var attempt: UUID?

    init(store: PairingStore = PairingStore()) { self.store = store }

    func pair(payload: PairingPayload, endpoint: NWEndpoint, expectedMacID: UUID,
              request: PairRequestMessage) async throws -> PairedPeer {
        try await pair(key: SymmetricKey(data: payload.pairSecret), identity: payload.identity,
                       endpoint: endpoint, expectedMacID: expectedMacID, request: request)
    }

    func pair(pin: String, pairID: Data, endpoint: NWEndpoint, expectedMacID: UUID,
              request: PairRequestMessage) async throws -> PairedPeer {
        let key = try KeyDerivation.pinKey(pin: pin, pairID: pairID)
        let identity = pairID.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try await pair(key: key, identity: identity, endpoint: endpoint, expectedMacID: expectedMacID, request: request)
    }

    private func pair(key: SymmetricKey, identity: String, endpoint: NWEndpoint, expectedMacID: UUID,
                      request: PairRequestMessage) async throws -> PairedPeer {
        try Task.checkCancellation()
        cancel()
        let attempt = UUID()
        self.attempt = attempt
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let options = TLSConfig.tlsOptions(psk: key, identity: identity)
                let connection = NWConnection(to: endpoint, using: TLSConfig.parameters(control: options))
                self.connection = connection
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    Task { @MainActor in
                        guard let self, let connection, self.connection === connection else { return }
                        switch state {
                        case .ready: self.send(request, expectedMacID: expectedMacID, on: connection)
                        case .failed(let error), .waiting(let error): self.finish(.failure(Failure.network(error.localizedDescription)))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    guard let self, self.attempt == attempt else { return }
                    self.finish(.failure(Failure.expired))
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.attempt == attempt else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func send(_ request: PairRequestMessage, expectedMacID: UUID, on connection: NWConnection) {
        do {
            let data = try ControlMessage.pairRequest(request).encode(sequence: 0, sentAt: MonotonicClock.nanoseconds())
            let context = NWConnection.ContentContext(identifier: "pairing", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
                Task { @MainActor in
                    guard let self, let connection, self.connection === connection else { return }
                    if let error { self.finish(.failure(Failure.network(error.localizedDescription))); return }
                    self.receive(on: connection, expectedMacID: expectedMacID)
                }
            })
        } catch { finish(.failure(error)) }
    }

    private func receive(on connection: NWConnection, expectedMacID: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, _, complete, error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                do {
                    if let error { throw Failure.network(error.localizedDescription) }
                    guard complete, let data,
                          case let .pairResponse(response) = try ControlMessage.decode(data).message,
                          response.peerID == expectedMacID else { throw Failure.invalidResponse }
                    let peer = PairedPeer(peerID: response.peerID, ltk: response.ltk, name: response.name)
                    try self.store.save(peer)
                    self.finish(.success(peer))
                } catch { self.finish(.failure(error)) }
            }
        }
    }

    private func finish(_ result: Result<PairedPeer, Error>) {
        let completion = completion
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        attempt = nil
        completion?.resume(with: result)
    }
}
