import AppKit
import SwiftUI

@main struct PinshiftApp: App {
    @NSApplicationDelegateAdaptor(PinshiftDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            HostMenuView(model: delegate.model)
                .environment(\.locale, Locale(identifier: "en_US"))
        } label: {
            HostMenuLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class PinshiftDelegate: NSObject, NSApplicationDelegate {
    // The host lives for the entire app process, including before the menu opens.
    let model = HostModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.state.needsStop else { return .terminateNow }
        Task { await model.quit() }
        return .terminateLater
    }
}

private struct HostMenuLabel: View {
    @ObservedObject var model: HostModel

    var body: some View {
        Image(systemName: model.state.needsStop ? "location.fill" : "location")
            .accessibilityLabel("Pinshift")
            .help("Pinshift")
    }
}
