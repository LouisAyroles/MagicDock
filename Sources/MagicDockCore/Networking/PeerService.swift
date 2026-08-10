import Foundation
@preconcurrency import Network
import os

public final class PeerService: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (PeerCommand) async -> PeerResponse
    public typealias PeersChangedHandler = @Sendable ([DiscoveredPeer]) -> Void
    public typealias ErrorHandler = @Sendable (String) -> Void

    public static let serviceType = "_magicdock._tcp"

    private let nodeID: String
    private let displayName: String
    private let security: PeerSecurityContext
    private let queue = DispatchQueue(label: "io.github.LouisAyroles.MagicDock.peer-service")
    private let callbackLock = NSLock()
    private let logger = Logger(subsystem: "io.github.LouisAyroles.MagicDock", category: "PeerService")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var requestHandler: RequestHandler?
    private var peersChangedHandler: PeersChangedHandler?
    private var errorHandler: ErrorHandler?

    public init(nodeID: String, displayName: String, pairingKey: PairingKey?) {
        self.nodeID = nodeID
        self.displayName = displayName
        self.security = PeerSecurityContext(nodeID: nodeID, key: pairingKey)
    }

    deinit {
        listener?.cancel()
        browser?.cancel()
    }

    public func setRequestHandler(_ handler: @escaping RequestHandler) {
        callbackLock.withLock {
            requestHandler = handler
        }
    }

    public func setPeersChangedHandler(_ handler: @escaping PeersChangedHandler) {
        callbackLock.withLock {
            peersChangedHandler = handler
        }
    }

    public func setErrorHandler(_ handler: @escaping ErrorHandler) {
        callbackLock.withLock {
            errorHandler = handler
        }
    }

    public func updatePairingKey(_ key: PairingKey?) async {
        await security.updateKey(key)
    }

    public func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.browser?.cancel()
            self?.listener = nil
            self?.browser = nil
        }
    }

    public func send(_ command: PeerCommand, to peer: DiscoveredPeer) async throws -> PeerResponse {
        let requestData = try await security.seal(command)
        let responseData = try await PeerWire.request(endpoint: peer.endpoint, payload: requestData)
        let opened = try await security.open(responseData, as: PeerResponse.self)
        let response = opened.payload

        guard response.requestID == command.requestID else {
            throw PeerTransportError.mismatchedResponse
        }
        guard response.success else {
            throw PeerTransportError.peerRejected(response.message ?? "Unknown error")
        }
        return response
    }

    private func startOnQueue() {
        guard listener == nil, browser == nil else { return }

        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.start(queue: queue)
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.publish(results: results)
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    self?.report(error: "Bonjour discovery failed: \(error.localizedDescription)")
                }
            }
            browser.start(queue: queue)
            self.browser = browser
        } catch {
            report(
                error: PeerTransportError.listenerUnavailable(error.localizedDescription).localizedDescription
            )
        }
    }

    private var serviceName: String {
        let sanitizedName = displayName.replacingOccurrences(of: ".", with: "-")
        let shortID = nodeID.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()
        return String("\(sanitizedName) • \(shortID)".prefix(63))
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("MagicDock peer service is ready")
        case let .failed(error):
            report(error: "Peer listener failed: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func publish(results: Set<NWBrowser.Result>) {
        let ownServiceName = serviceName
        let peers = results.compactMap { result -> DiscoveredPeer? in
            guard case let .service(name, _, _, _) = result.endpoint,
                name != ownServiceName
            else {
                return nil
            }

            let separator = " • "
            let friendlyName = name.components(separatedBy: separator).first ?? name
            return DiscoveredPeer(id: name, displayName: friendlyName, endpoint: result.endpoint)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        let callback = callbackLock.withLock { peersChangedHandler }
        callback?(peers)
    }

    private func accept(_ connection: NWConnection) {
        let inbound = InboundPeerConnection(connection: connection, queue: queue) { [weak self] data in
            guard let self else { throw PeerTransportError.cancelled }
            return try await handleIncoming(data)
        }
        inbound.start()
    }

    private func handleIncoming(_ data: Data) async throws -> Data {
        let opened = try await security.open(data, as: PeerCommand.self)
        let command = opened.payload

        let handler = callbackLock.withLock { requestHandler }

        let response: PeerResponse
        if let handler {
            response = await handler(command)
        } else {
            response = PeerResponse(
                requestID: command.requestID,
                success: false,
                message: "The local command handler is unavailable."
            )
        }

        return try await security.seal(response)
    }

    private func report(error message: String) {
        logger.error("\(message, privacy: .public)")
        let callback = callbackLock.withLock { errorHandler }
        callback?(message)
    }
}
