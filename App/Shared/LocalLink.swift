import Foundation
import Network
import Security

// TLS with a 256-bit out-of-band shared key. No server certificate exceptions,
// cloud account, public endpoint, or unencrypted command transport.
enum LocalTLS {
    static let service = "_pinshift._tcp"
    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("pinshift-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        let p = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        p.includePeerToPeer = false
        p.prohibitedInterfaceTypes = [.cellular]
        return p
    }
}
final class MessageConnection {
    let connection: NWConnection
    var onMessage: ((WireMessage) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    private var buffer = Data()
    private var ready = false
    private var timeout: DispatchWorkItem?
    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.ready else { return }
            self.onState?(false, "Connection timed out. Check Wi-Fi and pairing."); self.cancel()
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: deadline)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.ready = true; self.timeout?.cancel(); self.onState?(true, nil); self.receive()
            case .failed(let error): self.onState?(false, error.localizedDescription); self.cancel()
            case .cancelled: self.onState?(false, nil)
            case .waiting: break // The connection can recover until its bounded timeout.
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func send(_ message: WireMessage) {
        guard ready, var data = try? JSONEncoder().encode(message), data.count < 65536 else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in if error != nil { self?.cancel() } })
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 65536 else { self.cancel(); return }
            while let index = self.buffer.firstIndex(of: 0x0A) {
                let line = Data(self.buffer[..<index]); self.buffer.removeSubrange(...index)
                guard let message = try? JSONDecoder().decode(WireMessage.self, from: line) else { self.cancel(); return }
                self.onMessage?(message)
            }
            if complete || error != nil {
                self.onState?(false, error?.localizedDescription ?? "Connection closed. Check the Mac and pairing.")
                self.cancel()
            } else { self.receive() }
        }
    }
    func cancel() { ready = false; timeout?.cancel(); connection.cancel() }
}
