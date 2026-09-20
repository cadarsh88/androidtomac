import Foundation
import Network

@MainActor
public protocol QuickShareServerDelegate: AnyObject {
    func serverDidStart(port: UInt16, endpointID: String)
    func serverDidFail(error: Error)
    func serverDidReceiveTransferRequest(transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection)
    func serverTransferProgressUpdated(connection: InboundNearbyConnection, progress: TransferProgress)
    func serverTransferCompleted(connection: InboundNearbyConnection, savedURLs: [URL])
    func serverTransferTerminated(connection: InboundNearbyConnection, error: Error?)
}

public final class QuickShareServer: NSObject, NetServiceDelegate, InboundNearbyConnectionDelegate, @unchecked Sendable {
    public static let shared = QuickShareServer()

    private var tcpListener: NWListener?
    private var mdnsService: NetService?
    private var endpointID: [UInt8] = []
    private var activeConnections: [String: InboundNearbyConnection] = [:]
    private var isRunning = false

    public weak var delegate: QuickShareServerDelegate?
    public var customDeviceName: String?

    private override init() {
        super.init()
    }

    public func start() throws {
        guard !isRunning else { return }

        endpointID = QuickShareServer.generateEndpointID()

        // Socket options tuned for high bandwidth
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.noDelay = true // Disable Nagle algorithm for low latency

        let params = NWParameters(tls: .none, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let listener = try NWListener(using: params)
        self.tcpListener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    let idString = String(bytes: self.endpointID, encoding: .ascii) ?? "????"
                    print("[QuickShareServer] TCP Listener ready on port \(port) (Endpoint: \(idString))")
                    self.publishBonjour(port: Int32(port))
                    DispatchQueue.main.async {
                        self.delegate?.serverDidStart(port: port, endpointID: idString)
                    }
                }
            case .failed(let error):
                print("[QuickShareServer] Listener failed: \(error)")
                DispatchQueue.main.async {
                    self.delegate?.serverDidFail(error: error)
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            let id = UUID().uuidString
            print("[QuickShareServer] Accepted new incoming connection: \(id)")
            let conn = InboundNearbyConnection(connection: connection, id: id)
            self.activeConnections[id] = conn
            conn.delegate = self
            conn.start()
        }

        listener.start(queue: .global(qos: .utility))
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        mdnsService?.stop()
        mdnsService = nil
        tcpListener?.cancel()
        tcpListener = nil
        for (_, conn) in activeConnections {
            conn.disconnect()
        }
        activeConnections.removeAll()
        print("[QuickShareServer] Server stopped")
    }

    public func submitConsent(transferID: String, accept: Bool) {
        guard let conn = activeConnections[transferID] else { return }
        conn.submitUserConsent(accepted: accept)
    }

    // MARK: - Bonjour Publishing

    private func publishBonjour(port: Int32) {
        let nameBytes: [UInt8] = [
            0x23, // PCP
            endpointID[0], endpointID[1], endpointID[2], endpointID[3],
            0xFC, 0x9F, 0x5E, // Service ID prefix
            0, 0
        ]
        let serviceName = Data(nameBytes).urlSafeBase64EncodedString()
        let deviceName = customDeviceName ?? Host.current().localizedName ?? "Mac"
        let endpointInfo = EndpointInfo(name: deviceName, deviceType: .computer)

        let service = NetService(domain: "", type: "_FC9F5ED42C8A._tcp.", name: serviceName, port: port)
        service.delegate = self
        let txtDict: [String: Data] = [
            "n": endpointInfo.serialize().urlSafeBase64EncodedString().data(using: .utf8)!
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
        service.publish()
        self.mdnsService = service
        print("[QuickShareServer] mDNS published: '\(serviceName)' (Name: '\(deviceName)', Port: \(port))")
    }

    private static func generateEndpointID() -> [UInt8] {
        var id = [UInt8]()
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for _ in 0..<4 {
            id.append(alphabet.randomElement()!)
        }
        return id
    }

    // MARK: - InboundNearbyConnectionDelegate

    public func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.serverDidReceiveTransferRequest(transfer: transfer, from: device, connection: connection)
        }
    }

    public func transferProgressDidUpdate(connection: InboundNearbyConnection, progress: TransferProgress) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.serverTransferProgressUpdated(connection: connection, progress: progress)
        }
    }

    public func transferDidFinishSuccessfully(connection: InboundNearbyConnection, savedURLs: [URL]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.serverTransferCompleted(connection: connection, savedURLs: savedURLs)
            self.activeConnections.removeValue(forKey: connection.id)
        }
    }

    public func connectionWasTerminated(connection: InboundNearbyConnection, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.serverTransferTerminated(connection: connection, error: error)
            self.activeConnections.removeValue(forKey: connection.id)
        }
    }
}
