# Architecture

`App/Mac` contains the SwiftUI menu bar host, Bonjour server, and launchd integration. `App/iOS` contains the companion, native search, QR scanner, and reconnecting Bonjour client. Shared models, map rendering, Keychain storage, and TLS framing live in `App/Shared`.

The Mac has one `MenuBarExtra` and runs as an accessory app (`LSUIElement`); it has no regular window or Dock icon. Its app delegate owns the host model, so discovery, connections, and recovery run even before the menu opens. The popover contains connection and pairing controls, an emergency Stop while simulation needs restoring, and Quit.

The iPhone presents a native MapKit map and a persistent SwiftUI sheet. A single navigation stack holds controls, search, and connection settings. Start/Stop uses a bottom safe-area inset and stays visible while the native list scrolls. Pulling up the sheet reveals favorites, stored in the companion's local preferences. Search and Connection open at medium height; accessibility text sizes use a large sheet. Compact and medium heights allow map interaction behind the sheet. A selected location remains a local draft until the Mac acknowledges it, so failed commands do not discard the user's choice.

The Mac advertises a random service identity using `_pinshift._tcp`. A QR code transfers that identity and a random 256-bit pairing key. Both apps store the key in Keychain. Network.framework authenticates and encrypts the connection with TLS 1.2 PSK and AES-128-GCM; there is no certificate-validation bypass. Reset pairing rotates the key and service identity and disconnects all remotes. Anyone possessing the code has control of this location simulator, so do not publish it.

Messages are newline-delimited JSON, capped at 64 KB. Commands are `state`, `select`, `target`, `start`, and `stop`. Each has a request UUID. The host serializes requests, validates coordinates and target selection, acknowledges commands, and broadcasts status. The remote disables commands when disconnected or awaiting an acknowledgement and never replays a Start command automatically after reconnecting.

`App/Resources/keeper.py` persists a conservative `simulationMayBeActive` flag before applying location. It uses the native `devicectl` coordinate/clear commands on the exact chosen device. If a clear fails, a durable restore request remains queued and launchd retries when the phone returns. A crash does not silently report that GPS was restored. A file lock plus heartbeat detects a departed host. No privileged daemon is installed.

State: `~/Library/Application Support/Pinshift/`. Worker log: `~/Library/Logs/Pinshift.log`. LaunchAgent: `~/Library/LaunchAgents/at.strics.pinshift.keeper.plist`.

Closing the menu popover keeps the server running. Quitting requests a restore; if the iPhone is unavailable, the worker continues the pending restore. Restarting the host does not silently resume a previous active location.
