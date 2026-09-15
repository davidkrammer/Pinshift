import SwiftUI

struct RemoteView: View {
    @ObservedObject var model: RemoteModel
    @State private var draft: Place?

    private var selected: Place { draft ?? model.state.place }

    var body: some View {
        Group {
            if model.pairing == nil {
                PairRemoteView(model: model)
            } else {
                PlaceMap(place: selected) { draft = $0 }
                    .ignoresSafeArea()
                    .sheet(isPresented: .constant(true)) {
                        RemoteControls(model: model, draft: $draft)
                    }
            }
        }
        .onChange(of: model.state.place) { _, place in
            // Keep a pending selection until the Mac actually acknowledges it.
            if draft?.id == place.id { draft = nil }
        }
        .onChange(of: model.pairing?.id) { _, _ in draft = nil }
    }
}

private enum RemoteRoute: Hashable {
    case search
    case connection
}

private struct RemoteControls: View {
    @ObservedObject var model: RemoteModel
    @Binding var draft: Place?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var path: [RemoteRoute] = []
    @State private var detent = PresentationDetent.height(240)

    private var selected: Place { draft ?? model.state.place }
    private var hasDraft: Bool { draft != nil && draft?.id != model.state.place.id }
    private var isFavorite: Bool { model.favorites.contains { $0.id == selected.id } }
    private var controls: LocationControls {
        LocationControls(state: model.state, pendingCommand: model.pendingCommand?.kind, connected: model.readyForCommands, place: selected)
    }
    private var status: String {
        if !model.connected { return "Mac disconnected" }
        if model.pendingCommand?.kind == "start" { return "Starting…" }
        if model.pendingCommand?.kind == "stop" { return "Restoring GPS…" }
        if model.state.phase == "clearing" || model.state.phase == "clearPending" { return model.state.title }
        if model.pending { return "Sending…" }
        if hasDraft { return "Not applied" }
        if model.state.phase == "applying" { return "Applying location…" }
        return model.state.title
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(selected.name).font(.headline)
                                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if hasDraft && !model.pending {
                                    Button("Discard selection", systemImage: "arrow.uturn.backward") { draft = nil }
                                        .labelStyle(.iconOnly)
                                }
                                if selected.name != "Choose a location" {
                                    Button(isFavorite ? "Remove favorite" : "Save favorite", systemImage: isFavorite ? "star.fill" : "star") {
                                        model.toggleFavorite(selected)
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                }
                            }

                            if hasDraft && model.state.needsStop {
                                Button("Move here", systemImage: "location.fill") {
                                    model.send("start", place: selected)
                                }
                                .disabled(!controls.canMove)
                            }

                            if !model.connected {
                                Button("Reconnect", systemImage: "arrow.clockwise") { model.reconnect() }
                            } else if model.state.target == nil {
                                Text("Connect an iPhone to your Mac.").font(.footnote).foregroundStyle(.secondary)
                            }

                            if let error = model.error {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            } else if model.state.phase == "clearPending" {
                                Text("Reconnect the iPhone to restore GPS.").font(.footnote).foregroundStyle(.secondary)
                            } else if model.state.phase == "failed" {
                                Text(model.state.detail).font(.footnote).foregroundStyle(.red)
                            }
                        }
                        .buttonStyle(.borderless)
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    Section("Favorites") {
                        if model.favorites.isEmpty {
                            Text("No favorites").foregroundStyle(.secondary)
                        }
                        ForEach(model.favorites) { place in
                            Button {
                                draft = place
                                if !typeSize.isAccessibilitySize { detent = .height(240) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(place.name).foregroundStyle(.primary)
                                    Text(place.name == "Dropped pin" ? place.coordinates : place.detail)
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .onDelete(perform: model.removeFavorites)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                actionButton
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Pinshift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { open(.search) } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { open(.connection) } label: {
                        Label("Connection", systemImage: "desktopcomputer")
                    }
                }
            }
            .navigationDestination(for: RemoteRoute.self) { route in
                switch route {
                case .search:
                    PlaceSearch(near: selected) { place in
                        draft = place
                        path.removeAll()
                    }
                case .connection:
                    ConnectionView(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(240), .medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.resizes)
        .interactiveDismissDisabled()
        .onChange(of: typeSize, initial: true) { _, size in
            if size.isAccessibilitySize { detent = .large }
        }
        .onChange(of: model.error) { _, error in
            if error != nil && detent == .height(240) { detent = .medium }
        }
    }

    private func open(_ route: RemoteRoute) {
        // A navigation snapshot keeps its original height during a sheet resize.
        // Lay out the destination at its final size in one update; keep that
        // height on Back so the native pop transition never races a resize.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            detent = typeSize.isAccessibilitySize ? .large : .medium
            path = [route]
        }
    }

    @ViewBuilder private var actionButton: some View {
        if controls.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(controls.title)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .accessibilityElement(children: .combine)
        } else {
            Button(role: controls.action == .stop ? .destructive : nil) {
                model.send(controls.action.rawValue, place: controls.action == .start ? selected : nil)
            } label: {
                Label(controls.title, systemImage: controls.action == .stop ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minHeight: 52)
            .disabled(!controls.enabled)
            .accessibilityHint(controls.action == .stop ? "Restore the iPhone’s real GPS location" : "Apply the selected location")
        }
    }
}

struct PairRemoteView: View {
    @ObservedObject var model: RemoteModel
    @State private var scan = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") { scan = true }
                    NavigationLink("Enter pairing code") { PairingCodeView(model: model) }
                } footer: {
                    Text("Open Pinshift in your Mac’s menu bar. Use the same Wi-Fi.")
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Connect Mac")
            .sheet(isPresented: $scan) {
                QRScanner { model.pair($0); scan = false }
            }
        }
    }
}

private struct PairingCodeView: View {
    @ObservedObject var model: RemoteModel
    @State private var code = ""

    var body: some View {
        Form {
            Section {
                TextField("Pairing code", text: $code, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Button("Connect") { model.pair(code) }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Pairing code")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionView: View {
    @ObservedObject var model: RemoteModel
    @State private var forget = false

    private var targetName: String {
        model.state.devices.first(where: { $0.id == model.state.target })?.name ?? "Not connected"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Mac", value: model.pairing?.name ?? "Not paired")
                LabeledContent("Status", value: model.connected ? "Connected" : "Disconnected")
                Button("Reconnect", systemImage: "arrow.clockwise") { model.reconnect() }
            }

            Section {
                if model.state.devices.count > 1 {
                    Picker("iPhone", selection: Binding(
                        get: { model.state.target ?? "" },
                        set: { model.send("target", target: $0) }
                    )) {
                        if model.state.target == nil { Text("Choose iPhone").tag("") }
                        if let id = model.state.target, !model.state.devices.contains(where: { $0.id == id }) {
                            Text("Disconnected iPhone").tag(id)
                        }
                        ForEach(model.state.devices) { Text($0.name).tag($0.id) }
                    }
                    .disabled(model.state.needsStop || model.pending || !model.connected)
                } else {
                    LabeledContent("iPhone", value: targetName)
                }
            }

            Section {
                Button("Forget Mac", role: .destructive) { forget = true }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget this Mac?", isPresented: $forget) {
            Button("Forget Mac", role: .destructive) { model.forget() }
        }
    }
}
