import Foundation
import Network
import CommonCrypto
import CryptoKit

public enum NearbyError: Error, LocalizedError {
    case protocolError(_ message: String)
    case requiredFieldMissing(_ message: String)
    case ukey2
    case inputOutput
    case canceled(reason: CancellationReason)

    public enum CancellationReason {
        case userRejected, userCanceled, notEnoughSpace, unsupportedType, timedOut
    }

    public var errorDescription: String? {
        switch self {
        case .protocolError(let msg): return "Protocol error: \(msg)"
        case .requiredFieldMissing(let field): return "Missing required field: \(field)"
        case .ukey2: return "UKEY2 handshake failed"
        case .inputOutput: return "I/O error during transfer"
        case .canceled(let reason): return "Transfer canceled (\(reason))"
        }
    }
}

open class NearbyConnection {
    public static let saneFrameLength: Int = 10 * 1024 * 1024
    private static let dispatchQueue = DispatchQueue(label: "com.cadarsh88.androidtomac.connection", qos: .utility)

    public let connection: NWConnection
    public let id: String
    public internal(set) var remoteDeviceInfo: RemoteDeviceInfo?
    public internal(set) var encryptionDone: Bool = false
    public internal(set) var lastError: Error?
    private var connectionClosed: Bool = false

    // UKEY2 cryptography state using native Apple CryptoKit
    internal var privateKey: P256.KeyAgreement.PrivateKey?
    internal var publicKey: P256.KeyAgreement.PublicKey?
    internal var ukeyClientInitMsgData: Data?
    internal var ukeyServerInitMsgData: Data?

    // SecureMessage session keys
    internal var decryptKey: [UInt8]?
    internal var encryptKey: [UInt8]?
    internal var recvHmacKey: SymmetricKey?
    internal var sendHmacKey: SymmetricKey?

    // Sequence numbers
    private var serverSeq: Int32 = 0
    private var clientSeq: Int32 = 0

    public private(set) var pinCode: String?
    public private(set) var authKey: SymmetricKey?

    private var payloadBuffers: [Int64: NSMutableData] = [:]

    public init(connection: NWConnection, id: String) {
        self.connection = connection
        self.id = id
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                self.connectionReady()
                self.receiveFrameAsync()
            } else if case .failed(let err) = state {
                self.lastError = err
                print("[NearbyConnection] Socket failed: \(err)")
                self.handleConnectionClosure()
            }
        }
        connection.start(queue: NearbyConnection.dispatchQueue)
    }

    open func connectionReady() {}

    open func handleConnectionClosure() {
        print("[NearbyConnection] Connection closed: \(id)")
    }

    open func protocolError() {
        disconnect()
    }

    open func processReceivedFrame(frameData: Data) {
        fatalError("Must be overridden by subclass")
    }

    func processTransferSetupFrame(_ frame: Sharing_Nearby_Frame) throws {
        fatalError("Must be overridden by subclass")
    }

    open func isServer() -> Bool {
        fatalError("Must be overridden by subclass")
    }

    func processFileChunk(frame: Location_Nearby_Connections_PayloadTransferFrame) throws {
        protocolError()
    }

    open func processBytesPayload(payload: Data, id: Int64) throws -> Bool {
        return false
    }

    // MARK: - Framing (4-byte length prefix)

    private func receiveFrameAsync() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if self.connectionClosed { return }
            if isComplete {
                self.handleConnectionClosure()
                return
            }
            if let error = error {
                self.lastError = error
                self.protocolError()
                return
            }
            guard let content = content, content.count == 4 else {
                return
            }

            // Diagnostic probe: Handle browser HTTP GET check (e.g. from Android browser to verify connectivity)
            if content[0] == 0x47 && content[1] == 0x45 && content[2] == 0x54 && content[3] == 0x20 {
                self.respondToDiagnosticsProbe()
                return
            }

            let frameLength: UInt32 = UInt32(content[0]) << 24 | UInt32(content[1]) << 16 | UInt32(content[2]) << 8 | UInt32(content[3])
            guard Int(frameLength) < NearbyConnection.saneFrameLength else {
                self.lastError = NearbyError.protocolError("Unexpected packet length: \(frameLength)")
                self.protocolError()
                return
            }
            self.receiveFramePayload(length: frameLength)
        }
    }

    private func respondToDiagnosticsProbe() {
        let body = """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1.0">
        <title>Quick Share Active</title>
        <style>body{font-family:system-ui,sans-serif;padding:24px;text-align:center;background:#f0fdf4;color:#14532d}
        .card{background:white;padding:20px;border-radius:12px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);max-width:380px;margin:auto}
        .status{display:inline-block;padding:6px 14px;border-radius:20px;background:#22c55e;color:white;font-weight:600;font-size:14px;margin-bottom:12px}
        h2{margin:8px 0;font-size:20px}p{font-size:14px;color:#374151;line-height:1.5}</style>
        </head><body><div class="card">
        <div class="status">&#x2714; WI-FI CONNECTIVITY OK</div>
        <h2>Mac is Reachable!</h2>
        <p>Your Android phone can successfully communicate with this Mac over Wi-Fi.</p>
        <p>Return to your file, tap <b>Share &rarr; Quick Share</b>, and select this Mac.</p>
        </div></body></html>
        """
        guard let bodyData = body.data(using: .utf8) else { return }
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var fullResponse = headers.data(using: .utf8)!
        fullResponse.append(bodyData)
        connection.send(content: fullResponse, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.disconnect()
        })
    }

    private func receiveFramePayload(length: UInt32) {
        var accumulated = Data()
        accumulated.reserveCapacity(Int(length))
        self.receiveFrameChunk(accumulated: accumulated, remaining: Int(length))
    }

    private func receiveFrameChunk(accumulated: Data, remaining: Int) {
        let chunkSize = min(remaining, 65536)
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkSize) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if self.connectionClosed { return }
            if isComplete {
                self.handleConnectionClosure()
                return
            }
            guard let content = content, !content.isEmpty else {
                if let error = error { self.lastError = error }
                self.protocolError()
                return
            }
            var newAccumulated = accumulated
            newAccumulated.append(content)
            let newRemaining = remaining - content.count
            if newRemaining <= 0 {
                self.processReceivedFrame(frameData: newAccumulated)
                self.receiveFrameAsync()
            } else {
                self.receiveFrameChunk(accumulated: newAccumulated, remaining: newRemaining)
            }
        }
    }

    public func sendFrameAsync(_ frame: Data, completion: (() -> Void)? = nil) {
        if connectionClosed { return }
        var lengthPrefixedData = Data(capacity: frame.count + 4)
        let length = frame.count
        lengthPrefixedData.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length)
        ])
        lengthPrefixedData.append(frame)

        connection.send(content: lengthPrefixedData, completion: .contentProcessed({ _ in
            completion?()
        }))
    }

    // MARK: - Encryption & Framing

    func encryptAndSendOfflineFrame(_ frame: Location_Nearby_Connections_OfflineFrame, completion: (() -> Void)? = nil) throws {
        var d2dMsg = Securegcm_DeviceToDeviceMessage()
        serverSeq += 1
        d2dMsg.sequenceNumber = serverSeq
        d2dMsg.message = try frame.serializedData()

        let serializedMsg = [UInt8](try d2dMsg.serializedData())
        let iv = Data.randomData(length: 16)
        var encryptedData = Data(count: serializedMsg.count + 16)
        var encryptedLength: size_t = 0

        encryptedData.withUnsafeMutableBytes {
            let status = CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                encryptKey, kCCKeySizeAES256,
                [UInt8](iv),
                serializedMsg, serializedMsg.count,
                $0.baseAddress, $0.count,
                &encryptedLength
            )
            guard status == kCCSuccess else { fatalError("CCCrypt encrypt error: \(status)") }
        }

        var hb = Securemessage_HeaderAndBody()
        hb.body = encryptedData.prefix(encryptedLength)
        hb.header = Securemessage_Header()
        hb.header.encryptionScheme = .aes256Cbc
        hb.header.signatureScheme = .hmacSha256
        hb.header.iv = iv
        var md = Securegcm_GcmMetadata()
        md.type = .deviceToDeviceMessage
        md.version = 1
        hb.header.publicMetadata = try md.serializedData()

        var smsg = Securemessage_SecureMessage()
        smsg.headerAndBody = try hb.serializedData()
        smsg.signature = Data(HMAC<SHA256>.authenticationCode(for: smsg.headerAndBody, using: sendHmacKey!))
        sendFrameAsync(try smsg.serializedData(), completion: completion)
    }

    func sendTransferSetupFrame(_ frame: Sharing_Nearby_Frame) throws {
        try sendBytesPayload(data: try frame.serializedData(), id: Int64.random(in: Int64.min...Int64.max))
    }

    public func sendBytesPayload(data: Data, id: Int64) throws {
        var transfer = Location_Nearby_Connections_PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadChunk.offset = 0
        transfer.payloadChunk.flags = 0
        transfer.payloadChunk.body = data
        transfer.payloadHeader.id = id
        transfer.payloadHeader.type = .bytes
        transfer.payloadHeader.totalSize = Int64(transfer.payloadChunk.body.count)
        transfer.payloadHeader.isSensitive = false

        var wrapper = Location_Nearby_Connections_OfflineFrame()
        wrapper.version = .v1
        wrapper.v1 = Location_Nearby_Connections_V1Frame()
        wrapper.v1.type = .payloadTransfer
        wrapper.v1.payloadTransfer = transfer
        try encryptAndSendOfflineFrame(wrapper)

        transfer.payloadChunk.flags = 1 // last chunk
        transfer.payloadChunk.offset = Int64(transfer.payloadChunk.body.count)
        transfer.payloadChunk.clearBody()
        wrapper.v1.payloadTransfer = transfer
        try encryptAndSendOfflineFrame(wrapper)
    }

    func decryptAndProcessReceivedSecureMessage(_ smsg: Securemessage_SecureMessage) throws {
        guard smsg.hasSignature, smsg.hasHeaderAndBody else {
            throw NearbyError.requiredFieldMissing("secureMessage.signature|headerAndBody")
        }
        let hmac = Data(HMAC<SHA256>.authenticationCode(for: smsg.headerAndBody, using: recvHmacKey!))
        guard hmac == smsg.signature else {
            throw NearbyError.protocolError("HMAC verification failed")
        }
        let headerAndBody = try Securemessage_HeaderAndBody(serializedData: smsg.headerAndBody)
        var decryptedData = Data(count: headerAndBody.body.count)

        var decryptedLength: Int = 0
        decryptedData.withUnsafeMutableBytes {
            let status = CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                decryptKey, kCCKeySizeAES256,
                [UInt8](headerAndBody.header.iv),
                [UInt8](headerAndBody.body), headerAndBody.body.count,
                $0.baseAddress, $0.count,
                &decryptedLength
            )
            guard status == kCCSuccess else { fatalError("CCCrypt decrypt error: \(status)") }
        }
        decryptedData = decryptedData.prefix(decryptedLength)
        let d2dMsg = try Securegcm_DeviceToDeviceMessage(serializedData: decryptedData)
        guard d2dMsg.hasMessage, d2dMsg.hasSequenceNumber else {
            throw NearbyError.requiredFieldMissing("d2dMessage.message|sequenceNumber")
        }
        clientSeq += 1
        guard d2dMsg.sequenceNumber == clientSeq else {
            throw NearbyError.protocolError("Sequence mismatch: expected \(clientSeq), got \(d2dMsg.sequenceNumber)")
        }

        let offlineFrame = try Location_Nearby_Connections_OfflineFrame(serializedData: d2dMsg.message)
        if offlineFrame.hasV1 && offlineFrame.v1.hasType, case .payloadTransfer = offlineFrame.v1.type {
            guard offlineFrame.v1.hasPayloadTransfer else {
                throw NearbyError.requiredFieldMissing("offlineFrame.v1.payloadTransfer")
            }
            let payloadTransfer = offlineFrame.v1.payloadTransfer
            let header = payloadTransfer.payloadHeader
            let chunk = payloadTransfer.payloadChunk
            guard header.hasType, header.hasID else {
                throw NearbyError.requiredFieldMissing("payloadHeader.type|id")
            }
            guard payloadTransfer.hasPayloadChunk, chunk.hasOffset, chunk.hasFlags else {
                throw NearbyError.requiredFieldMissing("payloadTransfer.payloadChunk|offset|flags")
            }

            if case .bytes = header.type {
                let payloadID = header.id
                if header.totalSize > NearbyConnection.saneFrameLength {
                    payloadBuffers.removeValue(forKey: payloadID)
                    throw NearbyError.protocolError("Payload too large: \(header.totalSize) bytes")
                }
                if payloadBuffers[payloadID] == nil {
                    payloadBuffers[payloadID] = NSMutableData(capacity: Int(header.totalSize))
                }
                let buffer = payloadBuffers[payloadID]!
                guard chunk.offset == buffer.count else {
                    payloadBuffers.removeValue(forKey: payloadID)
                    throw NearbyError.protocolError("Chunk offset mismatch: expected \(buffer.count), got \(chunk.offset)")
                }
                if chunk.hasBody {
                    buffer.append(chunk.body)
                }
                if (chunk.flags & 1) == 1 {
                    payloadBuffers.removeValue(forKey: payloadID)
                    if !(try processBytesPayload(payload: Data(buffer), id: payloadID)) {
                        let innerFrame = try Sharing_Nearby_Frame(serializedData: buffer as Data)
                        try processTransferSetupFrame(innerFrame)
                    }
                }
            } else if case .file = header.type {
                try processFileChunk(frame: payloadTransfer)
            }
        } else if offlineFrame.hasV1 && offlineFrame.v1.hasType, case .keepAlive = offlineFrame.v1.type {
            sendKeepAlive(ack: true)
        }
    }

    // MARK: - UKEY2 & Key Derivation with CryptoKit

    public static func pinCodeFromAuthKey(_ key: SymmetricKey) -> String {
        var hash: Int = 0
        var multiplier: Int = 1
        let keyBytes: [UInt8] = key.withUnsafeBytes { [UInt8]($0) }

        for byte in keyBytes {
            let sbyte = Int(Int8(bitPattern: byte))
            hash = (hash + sbyte * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }

        return String(format: "%04d", abs(hash))
    }

    public static func hkdf(inputKeyMaterial: SymmetricKey, salt: Data, info: Data, outputByteCount: Int) -> SymmetricKey {
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKeyMaterial, salt: salt, info: info, outputByteCount: outputByteCount)
    }

    func finalizeKeyExchange(peerKey: Securemessage_GenericPublicKey) throws {
        guard peerKey.hasEcP256PublicKey else {
            throw NearbyError.requiredFieldMissing("peerKey.ecP256PublicKey")
        }

        var clientX = peerKey.ecP256PublicKey.x
        var clientY = peerKey.ecP256PublicKey.y
        if clientX.count > 32 { clientX = clientX.suffix(32) }
        if clientY.count > 32 { clientY = clientY.suffix(32) }
        if clientX.count < 32 { clientX = Data(repeating: 0, count: 32 - clientX.count) + clientX }
        if clientY.count < 32 { clientY = Data(repeating: 0, count: 32 - clientY.count) + clientY }

        let x963Representation = Data([0x04]) + clientX + clientY
        let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: x963Representation)
        guard let privKey = privateKey else { throw NearbyError.ukey2 }

        let sharedSecret = try privKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let derivedSecretKey = sharedSecret.withUnsafeBytes { ptr in
            Data(SHA256.hash(data: Data(ptr)))
        }

        var ukeyInfo = Data()
        ukeyInfo.append(ukeyClientInitMsgData!)
        ukeyInfo.append(ukeyServerInitMsgData!)

        let authString = NearbyConnection.hkdf(
            inputKeyMaterial: SymmetricKey(data: derivedSecretKey),
            salt: "UKEY2 v1 auth".data(using: .utf8)!,
            info: ukeyInfo,
            outputByteCount: 32
        )
        let nextSecret = NearbyConnection.hkdf(
            inputKeyMaterial: SymmetricKey(data: derivedSecretKey),
            salt: "UKEY2 v1 next".data(using: .utf8)!,
            info: ukeyInfo,
            outputByteCount: 32
        )

        authKey = authString
        pinCode = NearbyConnection.pinCodeFromAuthKey(authString)

        let salt = Data([
            0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83, 0x46, 0xCA, 0x1C,
            0xEE, 0x8D, 0x39, 0x09, 0xB9, 0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D,
            0x4A, 0xB3, 0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10
        ])

        let d2dClientKey = NearbyConnection.hkdf(inputKeyMaterial: nextSecret, salt: salt, info: "client".data(using: .utf8)!, outputByteCount: 32)
        let d2dServerKey = NearbyConnection.hkdf(inputKeyMaterial: nextSecret, salt: salt, info: "server".data(using: .utf8)!, outputByteCount: 32)

        var sha = SHA256()
        sha.update(data: "SecureMessage".data(using: .utf8)!)
        let smsgSalt = Data(sha.finalize())

        let clientKey = NearbyConnection.hkdf(inputKeyMaterial: d2dClientKey, salt: smsgSalt, info: "ENC:2".data(using: .utf8)!, outputByteCount: 32).withUnsafeBytes { [UInt8]($0) }
        let clientHmacKey = NearbyConnection.hkdf(inputKeyMaterial: d2dClientKey, salt: smsgSalt, info: "SIG:1".data(using: .utf8)!, outputByteCount: 32)
        let serverKey = NearbyConnection.hkdf(inputKeyMaterial: d2dServerKey, salt: smsgSalt, info: "ENC:2".data(using: .utf8)!, outputByteCount: 32).withUnsafeBytes { [UInt8]($0) }
        let serverHmacKey = NearbyConnection.hkdf(inputKeyMaterial: d2dServerKey, salt: smsgSalt, info: "SIG:1".data(using: .utf8)!, outputByteCount: 32)

        if isServer() {
            decryptKey = clientKey
            recvHmacKey = clientHmacKey
            encryptKey = serverKey
            sendHmacKey = serverHmacKey
        } else {
            decryptKey = serverKey
            recvHmacKey = serverHmacKey
            encryptKey = clientKey
            sendHmacKey = clientHmacKey
        }
    }

    public func disconnect() {
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.handleConnectionClosure()
        })
        connectionClosed = true
    }

    public func sendDisconnectionAndDisconnect() throws {
        var offlineFrame = Location_Nearby_Connections_OfflineFrame()
        offlineFrame.version = .v1
        offlineFrame.v1.type = .disconnection
        offlineFrame.v1.disconnection = Location_Nearby_Connections_DisconnectionFrame()

        if encryptionDone {
            try encryptAndSendOfflineFrame(offlineFrame)
        } else {
            sendFrameAsync(try offlineFrame.serializedData())
        }
        disconnect()
    }

    public func sendKeepAlive(ack: Bool) {
        var offlineFrame = Location_Nearby_Connections_OfflineFrame()
        offlineFrame.version = .v1
        offlineFrame.v1.type = .keepAlive
        offlineFrame.v1.keepAlive.ack = ack
        do {
            if encryptionDone {
                try encryptAndSendOfflineFrame(offlineFrame)
            } else {
                sendFrameAsync(try offlineFrame.serializedData())
            }
        } catch {
            print("[NearbyConnection] Error sending keep-alive: \(error)")
        }
    }
}
