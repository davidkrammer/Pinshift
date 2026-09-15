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
    @Published private(set) var pendingCommand: WireMessage?
    @Published private(set) var favorites: [Place] = []
    var pending: Bool { pendingCommand != nil }
    var readyForCommands: Bool { connected && link != nil && Date().timeIntervalSince(lastState) < 12 }
    private var browser: NWBrowser?
    private var link: MessageConnection?
    private var endpoint: NWEndpoint?
    private var timer: Timer?
    private var lastState = Date.distantPast
    private var pendingTimeout: Task<Void, Never>?
    private var generation = UUID()
    init() {
        if let data = UserDefaults.standard.data(forKey: "favoritePlaces"),
           let saved = try? JSONDecoder().decode([Place].self, from: data) {
            favorites = saved.filter { $0.isValid }
        }
        if let d = SecureStore.load("remote"), let p = try? JSONDecoder().decode(Pairing.self, from: d) { pairing = p; browse() }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func toggleFavorite(_ place: Place) {
        guard place.isValid, place.name != "Choose a location" else { return }
        if favorites.contains(where: { $0.id == place.id }) {
            favorites.removeAll { $0.id == place.id }
        } else {
            favorites.insert(place, at: 0)
        }
        saveFavorites()
    }
    func removeFavorites(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { favorites.remove(at: index) }
        saveFavorites()
    }
    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "favoritePlaces")
        }
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
        guard !pending else { return }
        guard readyForCommands, let link else { error = "The Mac is unavailable. Reconnect before making changes."; return }
        let controls = LocationControls(state: state, pendingCommand: nil, connected: true, place: place ?? state.place)
        if kind == "start" {
            guard (controls.action == .start && controls.enabled) || controls.canMove else { return }
        } else if kind == "stop" {
            guard controls.action == .stop && controls.enabled else { return }
        }
        let message = WireMessage(kind: kind, place: place, target: target)
        error = nil; pendingCommand = message; link.send(message)
        pendingTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.pendingCommand?.id == message.id else { return }
            // Re-read the host before enabling another command; never replay it.
            self.reconnect()
            self.error = "The Mac did not confirm the change. Checking its status…"
        }
    }
    private func clearPendingCommand() {
        pendingTimeout?.cancel(); pendingTimeout = nil; pendingCommand = nil
    }
    private func disconnect() {
        generation = UUID(); browser?.cancel(); browser = nil; link?.onState = nil; link?.cancel(); link = nil; endpoint = nil; connected = false; connecting = false; clearPendingCommand()
    }
    private func browse() {
        guard let pairing else { return }
        let g = generation
        connecting = true; connectionText = "Looking for \(pairing.name)…"
        let p = NWParameters.tcp; p.includePeerToPeer = false; p.prohibitedInterfaceTypes = [.cellular]
        let b = NWBrowser(for: .bonjour(type: LocalTLS.service, domain: "local."), using: p)
        b.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                guard let self, self.generation == g else { return }
                if case .failed = s { self.connectionText = "Allow Local Network access in Settings, then reconnect."; self.connecting = false }
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
            else { self.connectionText = "Mac disconnected. Reconnecting…"; self.clearPendingCommand(); self.link = nil; if let error { self.connectionText = error } }
        }
        l.onMessage = { [weak self, weak l] message in
            guard let self, self.generation == g, self.link === l else { return }
            if let s = message.snapshot { self.state = s; self.connected = true; self.connecting = false; self.lastState = Date(); self.connectionText = "Connected to \(s.hostName)" }
            if message.id == self.pendingCommand?.id { self.clearPendingCommand() }
            if let error = message.error { self.error = error }
        }
        l.start()
    }
    private func tick() {
        if connected {
            if Date().timeIntervalSince(lastState) > 12 {
                connected = false; connectionText = "Mac connection lost."
                link?.onState = nil; link?.cancel(); link = nil; clearPendingCommand()
            }
            else { link?.send(WireMessage(kind: "state")) }
        } else if link == nil, let endpoint { connect(endpoint) }
    }
}
