import SwiftUI
import CoreImage.CIFilterBuiltins

struct HostView: View {
    @ObservedObject var model: HostModel
    @State private var search = false
    @State private var pairing = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image("Brand").resizable().frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) { Text("Pinshift").font(.system(size: 25, weight: .semibold, design: .rounded)); Text("A change of place.").font(.subheadline).foregroundStyle(.secondary) }
                }.padding(.top, 24)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("IPHONE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if model.state.devices.isEmpty {
                        Label("Waiting for your iPhone", systemImage: "iphone").font(.subheadline)
                        Text("Connect it to this Mac by USB or through Xcode over Wi-Fi.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("iPhone", selection: Binding(get: { model.state.target ?? "" }, set: model.selectTarget)) {
                            ForEach(model.state.devices) { Text($0.name).tag($0.id) }
                            if let id = model.state.target, !model.state.devices.contains(where: { $0.id == id }) { Text("Disconnected iPhone").tag(id) }
                        }.labelsHidden().disabled(model.state.needsStop)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("LOCATION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(model.state.place.name).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(model.state.place.coordinates).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Button { search = true } label: { Label("Search places", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }.controlSize(.large)
                }
                if !model.favorites.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SAVED PLACES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(model.favorites.prefix(5)) { place in
                            Button { model.select(place) } label: { Label(place.name, systemImage: "bookmark").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(.vertical, 4)
                        }
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Circle().fill(model.state.active ? Color.accentColor : Color.secondary).frame(width: 7, height: 7); Text(model.state.title).font(.subheadline.weight(.medium)) }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(4) }
                    if model.state.phase == "clearPending" { Text("The Mac will restore GPS when this iPhone reconnects.").font(.caption).foregroundStyle(.secondary) }
                    Button { Task { await model.command(WireMessage(kind: model.state.needsStop ? "stop" : "start")) } } label: {
                        Label(model.state.needsStop ? "Stop & restore GPS" : "Start location", systemImage: model.state.needsStop ? "stop.fill" : "play.fill").frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.state.needsStop && (model.state.target == nil || model.state.place.name == "Choose a location"))
                }
                Divider()
                Button { pairing = true } label: { Label("Pair iPhone remote", systemImage: "qrcode").frame(maxWidth: .infinity) }.controlSize(.large)
                Text("Stays ready in your menu bar.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(24).frame(width: 310).background(.background)
            ZStack(alignment: .topTrailing) {
                PlaceMap(place: model.state.place, select: model.select)
                Button { model.toggleFavorite() } label: { Image(systemName: model.favorites.contains(where: { $0.id == model.state.place.id }) ? "bookmark.fill" : "bookmark").padding(10) }.buttonStyle(.bordered).help("Save this place").padding(20)
            }
        }.frame(minWidth: 860, minHeight: 640)
        .sheet(isPresented: $search) { PlaceSearch(select: model.select) }
        .sheet(isPresented: $pairing) { if let server = model.server { PairingSheet(server: server) } }
    }
}
struct PairingSheet: View {
    @ObservedObject var server: HostServer
    @Environment(\.dismiss) var dismiss
    @State private var reset = false
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 38)).foregroundStyle(Color.accentColor)
            Text("Your iPhone. Your remote.").font(.title2.weight(.semibold))
            Text("Open Pinshift on your iPhone and scan this code.\nKeep both devices on the same Wi-Fi network.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let image = qr(server.pairing.url) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 224, height: 224).padding(18).background(.white, in: RoundedRectangle(cornerRadius: 20)) }
            Label(server.clients > 0 ? "\(server.clients) remote connected" : (server.available ? "Ready to pair" : "Starting local connection…"), systemImage: server.clients > 0 ? "checkmark.circle.fill" : "wifi").foregroundStyle(server.clients > 0 ? Color.accentColor : Color.secondary)
            if let error = server.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("The code is private. It gives control of this Mac’s location simulator.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Copy pairing code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(server.pairing.url, forType: .string) }
                Button("Reset pairing") { reset = true }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 460)
        .confirmationDialog("Disconnect all paired remotes?", isPresented: $reset) { Button("Reset pairing", role: .destructive) { server.resetPairing() } }
    }
    private func qr(_ string: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator(); f.message = Data(string.utf8); f.correctionLevel = "M"
        guard let image = f.outputImage, let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: .init(width: 224, height: 224))
    }
}
