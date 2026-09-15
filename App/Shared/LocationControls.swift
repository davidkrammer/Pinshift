import Foundation

/// Acknowledging a request is separate from finishing the device operation.
struct LocationControls {
    enum Action: String { case start, stop }

    var state: HostSnapshot
    var pendingCommand: String?
    var connected: Bool
    var place: Place

    private var restoring: Bool { state.phase == "clearing" || state.phase == "clearPending" }
    private var validSelection: Bool {
        state.target != nil && place.isValid && place.name != "Choose a location"
    }

    var action: Action {
        if pendingCommand == "stop" || restoring { return .stop }
        if pendingCommand == "start" { return .start }
        return state.needsStop ? .stop : .start
    }

    var busy: Bool { pendingCommand != nil || state.phase == "clearing" }
    var title: String {
        if pendingCommand == "stop" || state.phase == "clearing" { return "Stopping…" }
        if pendingCommand == "start" { return "Starting…" }
        return action == .stop ? "Stop" : "Start"
    }

    var enabled: Bool {
        guard connected, !busy else { return false }
        return action == .stop || (!state.busy && validSelection)
    }

    var canMove: Bool { connected && !busy && state.active && validSelection }
}
