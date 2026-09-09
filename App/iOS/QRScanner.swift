import SwiftUI
import AVFoundation

struct QRScanner: View {
    var found: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var allowed = false
    @State private var checked = false
    var body: some View {
        NavigationStack {
            Group {
                if allowed { CameraScanner(found: found).ignoresSafeArea(edges: .bottom).overlay(alignment: .bottom) { Text("Scan the code shown in Pinshift on your Mac").padding(20).background(.regularMaterial, in: Capsule()).padding(20) } }
                else { ContentUnavailableView("Camera access needed", systemImage: "camera", description: Text(checked ? "Enable Camera access for Pinshift in Settings, or enter the pairing code instead." : "Requesting camera access…")) }
            }.navigationTitle("Pair with Mac").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.task { allowed = await AVCaptureDevice.requestAccess(for: .video); checked = true }
    }
}
struct CameraScanner: UIViewControllerRepresentable {
    var found: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(found: found) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}
final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    let found: (String) -> Void
    var preview: AVCaptureVideoPreviewLayer?
    var done = false
    init(found: @escaping (String) -> Void) { self.found = found; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }; session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); preview = layer
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); DispatchQueue.global(qos: .utility).async { self.session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, value.hasPrefix("pinshift://") else { return }
        done = true; found(value)
    }
}
