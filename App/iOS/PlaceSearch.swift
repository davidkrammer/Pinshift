import MapKit
import SwiftUI

struct PlaceSearch: View {
    var near: Place
    var select: (Place) -> Void
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            if let coordinate = coordinatePlace {
                Button { select(coordinate) } label: {
                    resultLabel(title: coordinate.coordinates, subtitle: "Coordinates", symbol: "mappin")
                }
                .foregroundStyle(.primary)
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                Button {
                    select(Place(
                        name: item.name ?? "Location",
                        detail: address(for: item),
                        latitude: item.placemark.coordinate.latitude,
                        longitude: item.placemark.coordinate.longitude
                    ))
                } label: {
                    resultLabel(
                        title: item.name ?? "Location",
                        subtitle: address(for: item),
                        symbol: item.pointOfInterestCategory == nil ? "mappin" : "mappin.and.ellipse"
                    )
                }
                .foregroundStyle(.primary)
            }
        }
        .overlay {
            if busy {
                ProgressView()
            } else if let error {
                ContentUnavailableView("Search unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if !query.isEmpty && results.isEmpty && coordinatePlace == nil {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Place or coordinates")
        .autocorrectionDisabled()
        .task(id: query) { await search() }
    }

    private func resultLabel(title: String, subtitle: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func address(for item: MKMapItem) -> String {
        let place = item.placemark
        let street = [place.subThoroughfare, place.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let components = [street, place.locality, place.administrativeArea, place.country].compactMap { $0 }
        var seen = Set([item.name?.lowercased() ?? ""])
        return components.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
    }

    private var coordinatePlace: Place? {
        let parts = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else { return nil }
        let place = Place(name: "Dropped pin", detail: "Custom coordinates", latitude: latitude, longitude: longitude)
        return place.isValid ? place : nil
    }

    @MainActor private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        error = nil
        busy = false
        guard !text.isEmpty, coordinatePlace == nil else { return }
        busy = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.region = MKCoordinateRegion(
                center: near.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
            )
            request.resultTypes = [.address, .pointOfInterest]
            let response = try await MKLocalSearch(request: request).start()
            try Task.checkCancellation()
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            var seen = Set<String>()
            results = response.mapItems.filter { item in
                let coordinate = item.placemark.coordinate
                let key = "\(item.name?.lowercased() ?? ""):\(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))"
                return seen.insert(key).inserted
            }
            busy = false
        } catch is CancellationError {
            // A new query owns the loading state.
        } catch {
            guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            self.error = "Enter coordinates or select a point on the map."
            busy = false
        }
    }
}
