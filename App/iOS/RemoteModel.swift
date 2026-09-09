import Foundation
import Network
import Combine

@MainActor final class RemoteModel: ObservableObject {
    @Published var pairing: Pairing?
    @Published var state = HostSnapshot()
    @Published var connected = false
    @Published var connecting = false
    @Published var connectionText = "Pair with your Mac to begin."
    @Published var error: String?
    @Published var pending = false
    private var browser: NWBrowser?
    private var link: MessageConnection?
    private var endpoint: NWEndpoint?
    private var timer: Timer?
    private var lastState = Date.distantPast
    private var pendingID: String?
    private var generation = UUID()
    init() {
        if let d = SecureStore.load("remote"), let p = try? JSONDecoder().decode(Pairing.self, from: d) { pairing = p; browse() }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func pair(_ code: String) {
        do {
            let p = try Pairing(url: code)
            try SecureStore.save(JSONEncoder().encode(p), account: "remote")
            disconnect(); pairing = p; error = nil; browse()
        } catch { self.error = error.localizedDescription }
    }
    func forget() { disconnect(); SecureStore.remove("remote"); pairing = nil; connectionText = "Pair with your Mac to begin."; error = nil }
    func reconnect() { guard pairing != nil else { return }; disconnect(); browse() }
    func send(_ kind: String, place: Place? = nil, target: String? = nil) {
        guard connected, !pending, Date().timeIntervalSince(lastState) < 12 else { error = "The Mac is unavailable. Reconnect before making changes."; return }
        let message = WireMessage(kind: kind, place: place, target: target)
        error = nil; pending = true; pendingID = message.id; link?.send(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.pendingID == message.id else { return }
            self.pending = false; self.pendingID = nil; self.error = "The Mac did not confirm the change. Check its status before retrying."
        }
    }
    private func disconnect() {
        generation = UUID(); browser?.cancel(); browser = nil; link?.onState = nil; link?.cancel(); link = nil; endpoint = nil; connected = false; connecting = false; pending = false; pendingID = nil
    }
    private func browse() {
        guard let pairing else { return }
        let g = generation
        connecting = true; connectionText = "Looking for \(pairing.name)…"
        let p = NWParameters.tcp; p.includePeerToPeer = false; p.prohibitedInterfaceTypes = [.cellular]
        let b = NWBrowser(for: .bonjour(type: LocalTLS.service, domain: "local."), using: p)
        b.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                if case .failed = s { self?.connectionText = "Allow Local Network access in Settings, then reconnect."; self?.connecting = false }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
            guard let self, self.generation == g else { return }
            let match = results.first { result in if case .service(let name, _, _, _) = result.endpoint { return name == pairing.id }; return false }
            if let match { self.endpoint = match.endpoint; if self.link == nil { self.connect(match.endpoint) } }
            else { self.endpoint = nil; if !self.connected { self.connectionText = "Waiting for \(pairing.name). Keep Pinshift open on the same Wi-Fi." } }
            }
        }
        browser = b; b.start(queue: .main)
    }
    private func connect(_ endpoint: NWEndpoint) {
        guard let pairing else { return }
        connecting = true; connectionText = "Connecting securely…"
        let g = generation; let l = MessageConnection(NWConnection(to: endpoint, using: LocalTLS.parameters(key: pairing.key)))
        link = l
        l.onState = { [weak self, weak l] ready, error in
            guard let self, self.generation == g, self.link === l else { return }
            self.connecting = !ready; self.connected = false
            if ready { l?.send(WireMessage(kind: "state")) }
            else { self.connectionText = "Mac disconnected. Reconnecting…"; self.pending = false; self.link = nil; if let error { self.connectionText = error } }
        }
        l.onMessage = { [weak self, weak l] message in
            guard let self, self.generation == g, self.link === l else { return }
            if let s = message.snapshot { self.state = s; self.connected = true; self.connecting = false; self.lastState = Date(); self.connectionText = "Connected to \(s.hostName)" }
            if message.id == self.pendingID { self.pending = false; self.pendingID = nil }
            if let error = message.error { self.error = error }
        }
        l.start()
    }
    private func tick() {
        if connected {
            if Date().timeIntervalSince(lastState) > 12 { connected = false; connectionText = "Mac connection lost."; link?.cancel(); link = nil }
            else { link?.send(WireMessage(kind: "state")) }
        } else if link == nil, let endpoint { connect(endpoint) }
    }
}
