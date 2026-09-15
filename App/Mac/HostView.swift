import CoreImage.CIFilterBuiltins
import SwiftUI

struct HostMenuView: View {
    @ObservedObject var model: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pinshift").font(.headline)

            if let server = model.server {
                HostConnectionView(server: server)
            } else {
                ProgressView("Connecting…").controlSize(.small)
            }

            if model.state.needsStop {
                Divider()
                Label(model.state.title, systemImage: "location.fill")
                    .font(.callout)
                Button("Stop", systemImage: "stop.fill") {
                    Task { await model.command(WireMessage(kind: "stop")) }
                }
                .accessibilityHint("Restore the iPhone’s real GPS location")
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit Pinshift") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
    }
}

private struct HostConnectionView: View {
    @ObservedObject var server: HostServer
    @State private var showingCode = false
    @State private var reset = false
    @State private var copied = false

    private var status: String {
        if !server.available { return "Connecting…" }
        if server.clients == 0 { return "Not connected" }
        return server.clients == 1 ? "Connected" : "\(server.clients) connected"
    }

    var body: some View {
        LabeledContent("iPhone", value: status)

        if server.clients == 0 || showingCode {
            if server.available, let code = qrImage {
                Image(nsImage: code)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(12)
                    .background(.white)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("iPhone pairing QR code")
                Text("Scan in Pinshift on your iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(copied ? "Copied" : "Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.pairing.url, forType: .string)
                    copied = true
                }
                .disabled(!server.available)
                Spacer()
                if server.clients > 0 {
                    Button("Done") { showingCode = false }
                }
            }
        } else {
            Button("Pair iPhone", systemImage: "qrcode") {
                showingCode = true
                copied = false
            }
        }

        if let error = server.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }

        Menu("Pairing") {
            Button("Reset pairing…", role: .destructive) { reset = true }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .confirmationDialog("Disconnect paired iPhones?", isPresented: $reset) {
            Button("Reset pairing", role: .destructive) {
                server.resetPairing()
                copied = false
                showingCode = true
            }
        }
    }

    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(server.pairing.url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 200, height: 200))
    }
}
