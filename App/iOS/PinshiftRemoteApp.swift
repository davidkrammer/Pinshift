import SwiftUI

@main struct PinshiftRemoteApp: App {
    @StateObject var model = RemoteModel()
    @Environment(\.scenePhase) var scenePhase
    var body: some Scene {
        WindowGroup {
            RemoteView(model: model).environment(\.locale, Locale(identifier: "en_US"))
                .onOpenURL { model.pair($0.absoluteString) }
                .onChange(of: scenePhase) { _, p in if p == .active && !model.connected { model.reconnect() } }
        }
    }
}
