import XCTest
import Network
@testable import Pinshift

final class LinkTests: XCTestCase {
    @MainActor func testEncryptedLocalCommandRoundTrip() async throws {
        let ready = expectation(description: "TLS authenticated and status returned")
        let key = Data(repeating: 13, count: 32)
        let listener = try NWListener(using: LocalTLS.parameters(key: key), on: .any)
        var server: MessageConnection?
        var client: MessageConnection?
        listener.newConnectionHandler = { connection in
            let link = MessageConnection(connection); server = link
            link.onMessage = { request in link.send(WireMessage(kind: "state", id: request.id, snapshot: HostSnapshot())) }
            link.start()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                let c = MessageConnection(NWConnection(host: "127.0.0.1", port: port, using: LocalTLS.parameters(key: key))); client = c
                c.onState = { connected, _ in if connected { c.send(WireMessage(kind: "state")) } }
                c.onMessage = { reply in if reply.kind == "state", reply.snapshot != nil { ready.fulfill() } }
                c.start()
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 15)
        client?.cancel(); server?.cancel(); listener.cancel()
    }
    @MainActor func testWrongPairingKeyCannotSendCommands() async throws {
        let rejected = expectation(description: "Wrong key rejected")
        let acceptedCommand = expectation(description: "No unauthorized command")
        acceptedCommand.isInverted = true
        let listener = try NWListener(using: LocalTLS.parameters(key: Data(repeating: 1, count: 32)), on: .any)
        var server: MessageConnection?; var client: MessageConnection?
        listener.newConnectionHandler = { connection in
            let link = MessageConnection(connection); server = link
            link.onMessage = { _ in acceptedCommand.fulfill() }; link.start()
        }
        var reported = false
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                let c = MessageConnection(NWConnection(host: "127.0.0.1", port: port, using: LocalTLS.parameters(key: Data(repeating: 2, count: 32)))); client = c
                c.onState = { connected, error in
                    if connected { c.send(WireMessage(kind: "start")) }
                    else if error != nil && !reported { reported = true; rejected.fulfill() }
                }; c.start()
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [rejected, acceptedCommand], timeout: 15)
        client?.cancel(); server?.cancel(); listener.cancel()
    }
}
