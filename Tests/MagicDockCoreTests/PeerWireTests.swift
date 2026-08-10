import Foundation
@preconcurrency import Network
import Testing

@testable import MagicDockCore

@Suite("Peer wire transport")
struct PeerWireTests {
    @Test("Round trips a framed message over loopback")
    func roundTripsOverLoopback() async throws {
        let queue = DispatchQueue(label: "MagicDockCoreTests.PeerWire")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        listener.newConnectionHandler = { connection in
            let inbound = InboundPeerConnection(connection: connection, queue: queue) { request in
                Data(request.reversed())
            }
            inbound.start()
        }

        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { state in
                continuation.yield(state)
                if case .failed = state {
                    continuation.finish()
                }
            }
        }
        listener.start(queue: queue)

        var listeningPort: NWEndpoint.Port?
        for await state in states {
            switch state {
            case .ready:
                listeningPort = listener.port
            case let .failed(error):
                throw PeerTransportError.network(error.localizedDescription)
            default:
                continue
            }
            break
        }

        let port = try #require(listeningPort)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let request = Data("MagicDock".utf8)
        let response = try await PeerWire.request(endpoint: endpoint, payload: request, timeout: 5)

        #expect(response == Data(request.reversed()))
    }
}
