import SwiftUI
import AppKit

@main struct PinshiftApp: App {
    @NSApplicationDelegateAdaptor(PinshiftDelegate.self) private var delegate
    @StateObject private var model = HostModel()
    var body: some Scene {
        WindowGroup("Pinshift", id: "main") {
            HostView(model: model).environment(\.locale, Locale(identifier: "en_US"))
                .onAppear { delegate.model = model }
        }.defaultSize(width: 1020, height: 700).windowStyle(.hiddenTitleBar)
        MenuBarExtra("Pinshift", systemImage: model.state.active ? "location.fill" : "mappin.and.ellipse") {
            MenuContent(model: model)
        }
    }
}
@MainActor final class PinshiftDelegate: NSObject, NSApplicationDelegate {
    weak var model: HostModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.state.needsStop else { return .terminateNow }
        Task { await model.quit() }; return .terminateLater
    }
}
struct MenuContent: View {
    @ObservedObject var model: HostModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(model.state.title)
        Text(model.state.place.name)
        Divider()
        Button("Open Pinshift") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if model.state.needsStop { Button("Stop & restore GPS") { Task { await model.command(WireMessage(kind: "stop")) } } }
        Divider()
        Button("Quit Pinshift") { NSApp.terminate(nil) }
    }
}
