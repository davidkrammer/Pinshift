import Foundation

enum CoreDeviceInventory {
    static func phones(in data: Data) throws -> [PhoneDevice] {
        guard let begin = data.firstIndex(of: 123),
              let json = try JSONSerialization.jsonObject(with: data[begin...]) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else {
            throw PinshiftError.message("Xcode returned an unreadable device list.")
        }
        return devices.compactMap { device in
            let properties = device["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any] ?? device["connectionProperties"] as? [String: Any] ?? [:]
            let state = properties["state"] as? [String: Any] ?? device["deviceProperties"] as? [String: Any] ?? [:]
            let tunnel = connection["state"] as? String ?? connection["tunnelState"] as? String ?? ""
            guard hardware["reality"] as? String == "physical",
                  hardware["deviceType"] as? String == "iPhone",
                  ["connected", "disconnected"].contains(tunnel),
                  ["wired", "localNetwork"].contains(connection["transportType"] as? String ?? ""),
                  let id = hardware["udid"] as? String else { return nil }
            return PhoneDevice(id: id, name: state["name"] as? String ?? "iPhone")
        }
    }
}
