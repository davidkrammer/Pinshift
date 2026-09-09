import Foundation
import Network
import Combine

@MainActor final class HostServer: ObservableObject {
    @Published var pairing: Pairing
    @Published var clients = 0
    @Published var error: String?
    @Published var available = false
    private var listener: NWListener?
    private var links: [UUID: MessageConnection] = [:]
    private var authenticatedLinks: Set<UUID> = []
    private var requests: Set<String> = []
    private var processing = false
    private weak var model: HostModel?
    init(model: HostModel) throws {
        self.model = model
        if let d = SecureStore.load("host"), let p = try? JSONDecoder().decode(Pairing.self, from: d) { pairing = p }
        else {
            pairing = Pairing(id: UUID().uuidString, name: model.state.hostName, key: SecureStore.randomKey())
            try SecureStore.save(JSONEncoder().encode(pairing), account: "host")
        }
        try listen()
    }
    func resetPairing() {
        links.values.forEach { $0.cancel() }; links.removeAll(); authenticatedLinks.removeAll(); clients = 0; available = false; listener?.cancel()
        pairing = Pairing(id: UUID().uuidString, name: model?.state.hostName ?? "Mac", key: SecureStore.randomKey())
        do { try SecureStore.save(JSONEncoder().encode(pairing), account: "host"); try listen() } catch { self.error = error.localizedDescription }
    }
    private func listen() throws {
        let listener = try NWListener(using: LocalTLS.parameters(key: pairing.key))
        listener.service = .init(name: pairing.id, type: LocalTLS.service)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state { case .ready: self?.available = true
                case .failed(let e): self?.available = false; self?.error = e.localizedDescription
                default: break }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        self.listener = listener; listener.start(queue: .main)
    }
    private func accept(_ connection: NWConnection) {
        guard links.count < 5 else { connection.cancel(); return }
        let id = UUID(); let link = MessageConnection(connection); links[id] = link
        link.onState = { [weak self, weak link] ready, _ in
            guard let self else { return }
            if ready { self.authenticatedLinks.insert(id); if let state = self.model?.state { link?.send(WireMessage(kind: "state", snapshot: state)) } }
            else { self.links.removeValue(forKey: id); self.authenticatedLinks.remove(id) }
            self.clients = self.authenticatedLinks.count
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let model = self.model, let link else { return }
            if message.kind == "state" { link.send(WireMessage(kind: "state", id: message.id, snapshot: model.state)); return }
            guard !self.processing else { link.send(WireMessage(kind: "error", id: message.id, error: "Another change is in progress.")); return }
            guard !self.requests.contains(message.id) else { link.send(WireMessage(kind: "state", id: message.id, snapshot: model.state)); return }
            self.processing = true
            self.requests.insert(message.id); if self.requests.count > 200 { self.requests = [message.id] }
            Task { @MainActor in
                await model.command(message); self.processing = false
                link.send(WireMessage(kind: model.error == nil ? "state" : "error", id: message.id, snapshot: model.state, error: model.error)); self.broadcast()
            }
        }
        link.start()
    }
    func broadcast() { guard var state = model?.state else { return }; state.updatedAt = Date().timeIntervalSince1970; links.values.forEach { $0.send(WireMessage(kind: "state", snapshot: state)) } }
}
