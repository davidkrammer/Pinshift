import MapKit
import SwiftUI

struct PlaceMap: View {
    var place: Place
    var select: (Place) -> Void
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                if place.name != "Choose a location" {
                    Marker(place.name, coordinate: place.coordinate)
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
