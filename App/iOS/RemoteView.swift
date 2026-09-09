import SwiftUI

struct RemoteView: View {
    @ObservedObject var model: RemoteModel
    @State private var search = false
    @State private var pairing = false
    @State private var draft: Place?
    var selected: Place { draft ?? model.state.place }
    var body: some View {
        Group {
            if model.pairing == nil { PairRemoteView(model: model) }
            else {
                ZStack(alignment: .top) {
                    PlaceMap(place: selected) { draft = $0 }.ignoresSafeArea()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Pinshift").font(.system(.title2, design: .rounded, weight: .bold))
                            HStack(spacing: 5) { Circle().fill(model.connected ? Color.accentColor : .orange).frame(width: 6, height: 6); Text(model.connected ? model.state.hostName : "Mac disconnected").font(.caption).lineLimit(1) }
                        }
                        Spacer()
                        Button { search = true } label: { Image(systemName: "magnifyingglass").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("Search places")
                        Button { pairing = true } label: { Image(systemName: "desktopcomputer").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("Mac connection")
                    }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 16).padding(.top, 8)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selected.name).font(.title2.weight(.semibold)).lineLimit(2)
                                Text(selected.coordinates).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if draft != nil { Button("Reset") { draft = nil }.font(.subheadline) }
                        }
                        if model.state.devices.count > 1 {
                            Picker("Target iPhone", selection: Binding(get: { model.state.target ?? "" }, set: { model.send("target", target: $0) })) { ForEach(model.state.devices) { Text($0.name).tag($0.id) } }.disabled(model.state.needsStop)
                        }
                        HStack(spacing: 6) { Circle().fill(model.state.active && model.connected ? Color.accentColor : .secondary).frame(width: 7, height: 7); Text(model.connected ? model.state.title : model.connectionText).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                        if model.state.phase == "clearPending" { Text("GPS will restore when the target iPhone reconnects to your Mac.").font(.caption).foregroundStyle(.secondary) }
                        HStack(spacing: 10) {
                            if draft != nil && model.state.needsStop {
                                Button { model.send("start", place: selected); draft = nil } label: { Text("Move here").frame(maxWidth: .infinity).padding(.vertical, 9) }.buttonStyle(.borderedProminent)
                            }
                            Button {
                                model.send(model.state.needsStop ? "stop" : "start", place: model.state.needsStop ? nil : selected)
                                if !model.state.needsStop { draft = nil }
                            } label: {
                                HStack { if model.pending { ProgressView().controlSize(.small) } else { Image(systemName: model.state.needsStop ? "stop.fill" : "play.fill") }; Text(model.state.needsStop ? "Stop & restore GPS" : "Start location") }.frame(maxWidth: .infinity).padding(.vertical, 9)
                            }.buttonStyle(.borderedProminent)
                        }.controlSize(.large).disabled(!model.connected || model.pending || (!model.state.needsStop && model.state.target == nil))
                    }.padding(22).background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
                }
            }
        }
        .tint(Color(red: 0.0, green: 0.52, blue: 0.46))
        .sheet(isPresented: $search) { PlaceSearch { draft = $0 } }
        .sheet(isPresented: $pairing) { ConnectionView(model: model) }
        .onChange(of: model.state.place.id) { _, _ in if draft?.id == model.state.place.id { draft = nil } }
    }
}
struct PairRemoteView: View {
    @ObservedObject var model: RemoteModel
    @State private var scan = false
    @State private var code = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    Image("Brand").resizable().frame(width: 116, height: 116).clipShape(RoundedRectangle(cornerRadius: 27)).padding(.top, 45)
                    VStack(spacing: 12) { Text("A change of place.").font(.system(size: 34, weight: .bold, design: .rounded)); Text("Choose a location on your iPhone.\nYour Mac takes it from there.").font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Open Pinshift on your Mac", systemImage: "desktopcomputer")
                        Label("Connect to the same Wi-Fi", systemImage: "wifi")
                        Label("Click Pair iPhone remote", systemImage: "qrcode")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    Button { scan = true } label: { Label("Scan Mac’s QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(.vertical, 9) }.buttonStyle(.borderedProminent).controlSize(.large)
                    DisclosureGroup("Enter pairing code instead") {
                        TextField("Paste the code from your Mac", text: $code, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).padding(.top, 12)
                        Button("Connect") { model.pair(code) }.buttonStyle(.bordered).disabled(code.isEmpty)
                    }.font(.subheadline).foregroundStyle(.secondary)
                    if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
                    Text("Private, encrypted, and only on your local network.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(28)
            }.navigationTitle("Pinshift").navigationBarTitleDisplayMode(.inline)
        }.sheet(isPresented: $scan) { QRScanner { model.pair($0); scan = false } }
    }
}
struct ConnectionView: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) var dismiss
    @State private var forget = false
    var body: some View {
        NavigationStack {
            List {
                Section("Mac") { Label(model.pairing?.name ?? "No Mac", systemImage: "desktopcomputer"); Text(model.connectionText).font(.subheadline).foregroundStyle(.secondary); Button("Reconnect") { model.reconnect() } }
                Section { Text("Keep Pinshift running on your Mac. Closing its window keeps the menu bar controller available. The Mac must stay awake and connected to the same Wi-Fi.").foregroundStyle(.secondary) }
                Section { Button("Forget this Mac", role: .destructive) { forget = true } }
            }.navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .confirmationDialog("Forget this Mac?", isPresented: $forget) { Button("Forget Mac", role: .destructive) { model.forget(); dismiss() } }
        }
    }
}
