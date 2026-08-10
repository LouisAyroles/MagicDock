import Foundation
@preconcurrency import Network

enum PeerWire {
    static let queue = DispatchQueue(label: "io.github.LouisAyroles.MagicDock.peer-wire")

    static func request(
        endpoint: NWEndpoint,
        payload: Data,
        timeout: TimeInterval = 240
    ) async throws -> Data {
        let frame = try FrameCodec.encode(payload)

        return try await withCheckedThrowingContinuation { continuation in
            let operation = PeerRequestOperation(
                endpoint: endpoint,
                frame: frame,
                queue: queue,
                timeout: timeout
            ) { result in
                continuation.resume(with: result)
            }
            operation.start()
        }
    }
}

private final class PeerRequestOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let frame: Data
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private let completionLock = NSLock()

    private var buffer = Data()
    private var hasSentRequest = false
    private var hasCompleted = false

    init(
        endpoint: NWEndpoint,
        frame: Data,
        queue: DispatchQueue,
        timeout: TimeInterval,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        self.connection = NWConnection(to: endpoint, using: .tcp)
        self.frame = frame
        self.queue = queue
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        // The connection owns this handler, which deliberately retains the
        // operation until `finish` clears the handler and breaks the cycle.
        connection.stateUpdateHandler = { [self] state in
            handle(state)
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(PeerTransportError.timedOut))
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendRequestIfNeeded()
        case let .failed(error):
            finish(.failure(PeerTransportError.network(error.localizedDescription)))
        case .cancelled:
            finish(.failure(PeerTransportError.cancelled))
        default:
            break
        }
    }

    private func sendRequestIfNeeded() {
        guard !hasSentRequest else { return }
        hasSentRequest = true

        connection.send(
            content: frame,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    finish(.failure(PeerTransportError.network(error.localizedDescription)))
                } else {
                    receiveNextChunk()
                }
            })
    }

    private func receiveNextChunk() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let content {
                buffer.append(content)
                do {
                    if let response = try FrameCodec.extractFrame(from: &buffer) {
                        finish(.success(response))
                        return
                    }
                } catch {
                    finish(.failure(error))
                    return
                }
            }

            if let error {
                finish(.failure(PeerTransportError.network(error.localizedDescription)))
            } else if isComplete {
                finish(.failure(FrameCodecError.connectionClosed))
            } else {
                receiveNextChunk()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        completionLock.lock()
        guard !hasCompleted else {
            completionLock.unlock()
            return
        }
        hasCompleted = true
        completionLock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }
}

final class InboundPeerConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let handler: @Sendable (Data) async throws -> Data
    private let completionLock = NSLock()

    private var buffer = Data()
    private var hasCompleted = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        timeout: TimeInterval = 240,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) {
        self.connection = connection
        self.queue = queue
        self.timeout = timeout
        self.handler = handler
    }

    func start() {
        // Keep the inbound handler alive while Network.framework owns the
        // connection. `finish` clears the callback to release the cycle.
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                receiveNextChunk()
            case .failed, .cancelled:
                finish()
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish()
        }
    }

    private func receiveNextChunk() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let content {
                buffer.append(content)
                do {
                    if let request = try FrameCodec.extractFrame(from: &buffer) {
                        process(request)
                        return
                    }
                } catch {
                    finish()
                    return
                }
            }

            if error != nil || isComplete {
                finish()
            } else {
                receiveNextChunk()
            }
        }
    }

    private func process(_ request: Data) {
        Task { [weak self, handler] in
            guard let self else { return }
            do {
                let response = try await handler(request)
                try send(response)
            } catch {
                finish()
            }
        }
    }

    private func send(_ response: Data) throws {
        let frame = try FrameCodec.encode(response)
        connection.send(
            content: frame,
            completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
    }

    private func finish() {
        completionLock.lock()
        guard !hasCompleted else {
            completionLock.unlock()
            return
        }
        hasCompleted = true
        completionLock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

public enum PeerTransportError: LocalizedError, Equatable, Sendable {
    case listenerUnavailable(String)
    case network(String)
    case timedOut
    case cancelled
    case peerRejected(String)
    case mismatchedResponse

    public var errorDescription: String? {
        switch self {
        case let .listenerUnavailable(message):
            "The local peer service could not start: \(message)"
        case let .network(message):
            "Peer network error: \(message)"
        case .timedOut:
            "The other Mac did not respond in time."
        case .cancelled:
            "The peer connection was cancelled."
        case let .peerRejected(message):
            "The other Mac rejected the request: \(message)"
        case .mismatchedResponse:
            "The response does not match the request."
        }
    }
}
