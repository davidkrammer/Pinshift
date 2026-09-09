# Architecture

`App/Mac` contains the SwiftUI host, menu bar controller, Bonjour server, and launchd integration. `App/iOS` contains the companion, QR scanner, and reconnecting Bonjour client. Shared models, MapKit search, Keychain storage, and TLS framing live in `App/Shared`.

The Mac advertises a random service identity using `_pinshift._tcp`. A QR code transfers that identity and a random 256-bit pairing key. Both apps store the key in Keychain. Network.framework authenticates and encrypts the connection with TLS 1.2 PSK and AES-128-GCM; there is no certificate-validation bypass. Reset pairing rotates the key and service identity and disconnects all remotes. Anyone possessing the code has control of this location simulator, so do not publish it.

Messages are newline-delimited JSON, capped at 64 KB. Commands are `state`, `select`, `target`, `start`, and `stop`. Each has a request UUID. The host serializes requests, validates coordinates and target selection, acknowledges commands, and broadcasts status. The remote disables commands when disconnected or awaiting an acknowledgement and never replays a Start command automatically after reconnecting.

`App/Resources/keeper.py` persists a conservative `simulationMayBeActive` flag before applying location. It uses the native `devicectl` coordinate/clear commands on the exact chosen device. If a clear fails, a durable restore request remains queued and launchd retries when the phone returns. A crash does not silently report that GPS was restored. A file lock plus heartbeat detects a departed host. No privileged daemon is installed.

State: `~/Library/Application Support/Pinshift/`. Worker log: `~/Library/Logs/Pinshift.log`. LaunchAgent: `~/Library/LaunchAgents/at.strics.pinshift.keeper.plist`.

Closing the Mac window keeps the server running. Quitting requests a restore; if the iPhone is unavailable, the worker continues the pending restore. Restarting the host does not silently resume a previous active location.
