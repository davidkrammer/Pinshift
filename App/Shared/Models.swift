import Foundation
import CoreLocation

struct Place: Codable, Equatable, Identifiable {
    var name: String
    var detail: String
    var latitude: Double
    var longitude: Double
    var id: String { "\(latitude),\(longitude)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) && name.count <= 160 && detail.count <= 240 }
    var coordinates: String { String(format: "%.5f, %.5f", latitude, longitude) }
    static let initial = Place(name: "Choose a location", detail: "Search or tap the map", latitude: 48.2082, longitude: 16.3738)
}
struct PhoneDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
}
struct HostSnapshot: Codable, Equatable {
    var place: Place = .initial
    var devices: [PhoneDevice] = []
    var target: String? = nil
    var phase = "idle"
    var detail = "Choose a location to begin."
    var desired = false
    var mayBeActive = false
    var hostName = "Mac"
    var updatedAt = Date().timeIntervalSince1970
    var active: Bool { phase == "active" }
    var needsStop: Bool { desired || mayBeActive }
    var busy: Bool { ["connecting", "applying", "clearing", "starting"].contains(phase) }
    var title: String {
        switch phase {
        case "active": return "Location active"
        case "cleared", "idle": return "Real GPS"
        case "clearPending": return "Waiting to restore GPS"
        case "waitingForDevice": return "Waiting for iPhone"
        case "clearing": return "Restoring GPS…"
        case "failed": return "Needs attention"
        default: return "Connecting…"
        }
    }
}
struct WireMessage: Codable {
    var kind: String
    var id: String = UUID().uuidString
    var place: Place? = nil
    var target: String? = nil
    var snapshot: HostSnapshot? = nil
    var error: String? = nil
}
struct Pairing: Codable {
    var id: String
    var name: String
    var key: Data
    var url: String {
        var c = URLComponents()
        c.scheme = "pinshift"; c.host = "pair"
        c.queryItems = [.init(name: "id", value: id), .init(name: "name", value: name), .init(name: "key", value: key.base64EncodedString())]
        return c.string!
    }
    init(id: String, name: String, key: Data) { self.id = id; self.name = name; self.key = key }
    init(url: String) throws {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "pinshift", c.host == "pair", let q = c.queryItems,
              let id = q.first(where: { $0.name == "id" })?.value, UUID(uuidString: id) != nil,
              let name = q.first(where: { $0.name == "name" })?.value, name.count <= 100,
              let keyString = q.first(where: { $0.name == "key" })?.value, let key = Data(base64Encoded: keyString), key.count == 32 else {
            throw PinshiftError.message("That pairing code is invalid. Open Pair iPhone on your Mac and try again.")
        }
        self.init(id: id, name: name, key: key)
    }
}
enum PinshiftError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
