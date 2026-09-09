import SwiftUI
import MapKit

struct PlaceMap: View {
    var place: Place
    var select: (Place) -> Void
    @State private var position: MapCameraPosition = .automatic
    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                Annotation(place.name, coordinate: place.coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 44)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                        .accessibilityLabel("Selected location: \(place.name)")
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                select(Place(name: "Dropped pin", detail: "Custom location", latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
        }
        .onAppear { center(place) }
        .onChange(of: place) { _, selection in center(selection) }
    }
    private func center(_ selection: Place) {
        position = .region(MKCoordinateRegion(center: selection.coordinate, span: .init(latitudeDelta: 0.025, longitudeDelta: 0.025)))
    }
}
struct PlaceSearch: View {
    var select: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if busy { ProgressView("Searching…") }
                if let error { Text(error).foregroundStyle(.secondary) }
                if let p = coordinatePlace { Button { choose(p) } label: { Label(p.coordinates, systemImage: "mappin") } }
                ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                    Button { choose(Place(name: item.name ?? "Location", detail: item.placemark.title ?? "", latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? "Location").foregroundStyle(.primary)
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
                if query.isEmpty { Text("Search a city, address, or landmark. You can also enter latitude, longitude.").foregroundStyle(.secondary).listRowSeparator(.hidden) }
            }
            .searchable(text: $query, prompt: "Place or coordinates")
            .onSubmit(of: .search) { Task { await search() } }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                await search()
            }
            .navigationTitle("Choose a location")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 480, height: 500)
        #endif
    }
    private var coordinatePlace: Place? {
        let parts = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]) else { return nil }
        let p = Place(name: "Dropped pin", detail: "Custom coordinates", latitude: a, longitude: b)
        return p.isValid ? p : nil
    }
    private func choose(_ place: Place) { select(place); dismiss() }
    @MainActor private func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
        let text = query
        busy = true; error = nil
        let r = MKLocalSearch.Request(); r.naturalLanguageQuery = query
        do {
            let response = try await MKLocalSearch(request: r).start()
            guard !Task.isCancelled, query == text else { return }
            results = response.mapItems; busy = false
            if results.isEmpty { error = "No places found. Try an address or coordinates." }
        } catch { if query == text { self.error = "Search unavailable. You can still enter coordinates or tap the map."; busy = false } }
    }
}
