import AppKit
import Combine
import Foundation

@MainActor final class HostModel: ObservableObject {
    @Published var state = HostSnapshot()
    @Published var error: String?
    @Published var favorites: [Place] = []
    @Published var server: HostServer?
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pinshift")
    private var lease: AppLivenessLease?
    private var timer: Timer?
    private var refreshing = false
    private var lastDevices = Date.distantPast
    private var requestID = UUID().uuidString
    private var timerTicks = 0
    private let label = "at.strics.pinshift.keeper"
    private var launchInstalled = false
    private var requestInFlight = false
    private var lastIssued = Date.distantPast
    init() {
        // Unit tests exercise isolated models and listeners, never the live helper.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        state.hostName = Host.current().localizedName ?? "Mac"
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lease = AppLivenessLease(url: root.appendingPathComponent("gui-liveness.lock"))
        if let d = try? Data(contentsOf: root.appendingPathComponent("selection.json")), let previous = try? JSONDecoder().decode(HostSnapshot.self, from: d) {
            state.place = previous.place; state.target = previous.target
        }
        favorites = (UserDefaults.standard.data(forKey: "favorites").flatMap { try? JSONDecoder().decode([Place].self, from: $0) }) ?? []
        Task {
            await refreshDevices()
            await refresh()
            if state.mayBeActive { await command(WireMessage(kind: "stop")) }
            do { server = try HostServer(model: self) } catch { self.error = error.localizedDescription }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in await self?.tick() } }
    }
    func select(_ place: Place) {
        guard place.isValid else { error = "Choose valid coordinates."; return }
        state.place = place; persistSelection()
        if state.desired { Task { await command(WireMessage(kind: "start", place: place)) } }
        server?.broadcast()
    }
    func selectTarget(_ id: String) {
        guard !state.needsStop else { error = "Restore GPS before changing the target iPhone."; return }
        guard state.devices.contains(where: { $0.id == id }) else { error = "That iPhone is no longer available. Reconnect it first."; return }
        state.target = id; persistSelection(); server?.broadcast()
    }
    func toggleFavorite() {
        if favorites.contains(where: { $0.id == state.place.id }) { favorites.removeAll { $0.id == state.place.id } }
        else { favorites.insert(state.place, at: 0); favorites = Array(favorites.prefix(30)) }
        if let d = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(d, forKey: "favorites") }
    }
    func command(_ message: WireMessage) async {
        if message.kind == "state" { return }
        guard !requestInFlight else { error = "Another change is still being applied. Try again shortly."; return }
        requestInFlight = true; defer { requestInFlight = false }
        error = nil
        if message.kind == "select", let p = message.place { select(p); return }
        if message.kind == "target", let id = message.target { selectTarget(id); return }
        guard message.kind == "start" || message.kind == "stop" else { error = "Unknown command."; return }
        if let place = message.place {
            guard place.isValid else { error = "Invalid coordinates."; return }; state.place = place
        }
        if message.kind == "start" {
            guard state.target != nil else { error = "Choose a connected iPhone first."; return }
            guard state.place.name != "Choose a location" else { error = "Choose a location first."; return }
        }
        state.desired = message.kind == "start"
        state.phase = state.desired ? "applying" : "clearing"
        state.detail = state.desired ? "Applying \(state.place.name)…" : "Restoring real GPS…"
        requestID = message.id; lastIssued = Date()
        do {
            try writeConfiguration()
            try await ensureWorker()
            persistSelection()
        } catch { self.error = error.localizedDescription; state.phase = "failed"; state.detail = error.localizedDescription }
        server?.broadcast()
    }
    private func persistSelection() { if let d = try? JSONEncoder().encode(state) { try? d.write(to: root.appendingPathComponent("selection.json"), options: .atomic) } }
    private func writeConfiguration() throws {
        let p = state.place
        var c: [String: Any] = ["cityID": p.id, "cityName": p.name, "country": p.detail, "latitude": p.latitude, "longitude": p.longitude, "retrySeconds": 5, "refreshSeconds": 10, "requestID": requestID, "simulationEnabled": state.desired, "appHeartbeatAt": Date().timeIntervalSince1970]
        if let target = state.target { c["targetUDID"] = target }
        let d = try JSONSerialization.data(withJSONObject: c)
        try d.write(to: root.appendingPathComponent("config.json"), options: .atomic)
    }
    private func ensureWorker() async throws {
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard let script = Bundle.main.url(forResource: "keeper", withExtension: "py") else { throw PinshiftError.message("The location helper is missing from the app.") }
        if !launchInstalled {
            let attributes: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/caffeinate", "-i", "/usr/bin/python3", script.path], "KeepAlive": ["SuccessfulExit": false], "RunAtLoad": true, "ThrottleInterval": 5, "ExitTimeOut": 25, "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: attributes, format: .xml, options: 0).write(to: plist, options: .atomic)
            _ = try? await run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
            launchInstalled = true
        }
        _ = try await run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"])
    }
    private func tick() async {
        timerTicks += 1
        if (state.desired || state.mayBeActive) && timerTicks % 15 == 0 { try? writeConfiguration() }
        await refresh()
        if Date().timeIntervalSince(lastDevices) > 15 { await refreshDevices() }
        server?.broadcast()
    }
    private func refresh() async {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("status.json")), let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        state.mayBeActive = s["simulationMayBeActive"] as? Bool ?? false
        if let id = s["requestID"] as? String, id != requestID, Date().timeIntervalSince(lastIssued) < 25 { return }
        state.phase = s["phase"] as? String ?? "idle"
        let updated = s["updatedAt"] as? Double ?? 0
        if state.desired && Date().timeIntervalSince1970 - updated > 35 { state.phase = "waitingForDevice" }
        state.detail = s["message"] as? String ?? state.title
        state.updatedAt = Date().timeIntervalSince1970
    }
    func refreshDevices() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }; lastDevices = Date()
        do {
            let d = try await run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--quiet", "--timeout", "10", "--json-output", "-"])
            state.devices = try CoreDeviceInventory.phones(in: d)
            if state.target == nil && state.devices.count == 1 { state.target = state.devices[0].id }
        } catch { if !state.desired { self.error = "Could not discover iPhones. Check Xcode and your USB or Wi-Fi connection." } }
    }
    func quit() async {
        await command(WireMessage(kind: "stop"))
        guard error == nil else {
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        // The durable worker owns the restore request if the phone is unavailable.
        for _ in 0..<12 {
            await refresh()
            if !state.mayBeActive && state.phase == "cleared" { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw PinshiftError.message(String(data: data, encoding: .utf8) ?? "Command failed") }
            return data
        }.value
    }
}
