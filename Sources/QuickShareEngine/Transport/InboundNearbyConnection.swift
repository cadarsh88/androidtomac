import Foundation
import Network
import CryptoKit
import CommonCrypto

public protocol InboundNearbyConnectionDelegate: AnyObject {
    func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection)
    func transferProgressDidUpdate(connection: InboundNearbyConnection, progress: TransferProgress)
    func connectionWasTerminated(connection: InboundNearbyConnection, error: Error?)
    func transferDidFinishSuccessfully(connection: InboundNearbyConnection, savedURLs: [URL])
}

public class InboundNearbyConnection: NearbyConnection, StreamingFileWriterDelegate {
    public enum State {
        case initial
        case receivedConnectionRequest
        case sentUkeyServerInit
        case receivedUkeyClientFinish
        case sentConnectionResponse
        case sentPairedKeyResult
        case receivedPairedKeyResult
        case waitingForUserConsent
        case receivingFiles
        case disconnected
    }

    public weak var delegate: InboundNearbyConnectionDelegate?
    private var currentState: State = .initial
    private var cipherCommitment: Data?
    private var fileWriters: [Int64: StreamingFileWriter] = [:]
    private var completedURLs: [URL] = []
    private var transferMetadata: TransferMetadata?
    private var isSleepingAssertionActive: Bool = false

    public override init(connection: NWConnection, id: String) {
        super.init(connection: connection, id: id)
    }

    public override func isServer() -> Bool {
        return true
    }

    public override func handleConnectionClosure() {
        super.handleConnectionClosure()
        currentState = .disconnected
        if isSleepingAssertionActive {
            SleepAssertionManager.shared.endActivity()
            isSleepingAssertionActive = false
        }
        for (_, writer) in fileWriters {
            writer.abort()
        }
        fileWriters.removeAll()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.connectionWasTerminated(connection: self, error: self.lastError)
        }
    }

    public override func processReceivedFrame(frameData: Data) {
        do {
            switch currentState {
            case .initial:
                let frame = try Location_Nearby_Connections_OfflineFrame(serializedData: frameData)
                try processConnectionRequestFrame(frame)
            case .receivedConnectionRequest:
                let msg = try Securegcm_Ukey2Message(serializedData: frameData)
                ukeyClientInitMsgData = frameData
                try processUkey2ClientInit(msg)
            case .sentUkeyServerInit:
                let msg = try Securegcm_Ukey2Message(serializedData: frameData)
                try processUkey2ClientFinish(msg, raw: frameData)
            case .receivedUkeyClientFinish:
                let frame = try Location_Nearby_Connections_OfflineFrame(serializedData: frameData)
                try processConnectionResponseFrame(frame)
            default:
                let smsg = try Securemessage_SecureMessage(serializedData: frameData)
                try decryptAndProcessReceivedSecureMessage(smsg)
            }
        } catch {
            lastError = error
            print("[InboundNearbyConnection] Error processing frame in state \(currentState): \(error)")
            protocolError()
        }
    }

    override func processTransferSetupFrame(_ frame: Sharing_Nearby_Frame) throws {
        if frame.hasV1 && frame.v1.hasType, case .cancel = frame.v1.type {
            print("[InboundNearbyConnection] Transfer cancelled by peer")
            try sendDisconnectionAndDisconnect()
            return
        }
        switch currentState {
        case .sentConnectionResponse:
            try processPairedKeyEncryptionFrame(frame)
        case .sentPairedKeyResult:
            try processPairedKeyResultFrame(frame)
        case .receivedPairedKeyResult:
            try processIntroductionFrame(frame)
        default:
            print("[InboundNearbyConnection] Unexpected frame in state: \(currentState)")
        }
    }

    // MARK: - High-Throughput Chunk Processing

    override func processFileChunk(frame: Location_Nearby_Connections_PayloadTransferFrame) throws {
        let payloadID = frame.payloadHeader.id
        guard let writer = fileWriters[payloadID] else {
            throw NearbyError.protocolError("Unknown payload ID: \(payloadID)")
        }

        let chunk = frame.payloadChunk
        if chunk.body.count > 0 {
            try writer.writeChunk(chunk.body, offset: chunk.offset)
        }

        // Check if last chunk (flags bit 0 == 1)
        if (chunk.flags & 1) == 1 {
            let finalURL = try writer.finalizeTransfer()
            completedURLs.append(finalURL)
            fileWriters.removeValue(forKey: payloadID)

            if fileWriters.isEmpty {
                if isSleepingAssertionActive {
                    SleepAssertionManager.shared.endActivity()
                    isSleepingAssertionActive = false
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.transferDidFinishSuccessfully(connection: self, savedURLs: self.completedURLs)
                }
                try sendDisconnectionAndDisconnect()
            }
        }
    }

    // MARK: - StreamingFileWriterDelegate

    public func fileWriterDidUpdateProgress(_ writer: StreamingFileWriter, progress: TransferProgress) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.transferProgressDidUpdate(connection: self, progress: progress)
        }
    }

    public func fileWriterDidFinish(_ writer: StreamingFileWriter, finalURL: URL) {}

    public func fileWriterDidFail(_ writer: StreamingFileWriter, error: Error) {
        lastError = error
        protocolError()
    }

    // MARK: - Handshake Details

    private func processConnectionRequestFrame(_ frame: Location_Nearby_Connections_OfflineFrame) throws {
        guard frame.hasV1 && frame.v1.hasConnectionRequest && frame.v1.connectionRequest.hasEndpointInfo else {
            throw NearbyError.requiredFieldMissing("connectionRequest.endpointInfo")
        }
        guard case .connectionRequest = frame.v1.type else {
            throw NearbyError.protocolError("Unexpected frame: \(frame.v1.type)")
        }
        guard let info = EndpointInfo(data: frame.v1.connectionRequest.endpointInfo) else {
            throw NearbyError.protocolError("Malformed endpoint info")
        }
        remoteDeviceInfo = RemoteDeviceInfo(name: info.name ?? "Android Device", type: info.deviceType)
        currentState = .receivedConnectionRequest
    }

    private func asSignedBigEndianBytes(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        while bytes.count > 1 && bytes[0] == 0 && bytes[1] < 128 {
            bytes.remove(at: 0)
        }
        if let first = bytes.first, first >= 128 {
            bytes.insert(0, at: 0)
        }
        return Data(bytes)
    }

    private func processUkey2ClientInit(_ msg: Securegcm_Ukey2Message) throws {
        guard msg.hasMessageType, msg.hasMessageData, case .clientInit = msg.messageType else {
            throw NearbyError.ukey2(reason: "Expected clientInit message type")
        }
        let clientInit = try Securegcm_Ukey2ClientInit(serializedData: msg.messageData)
        guard clientInit.version == 1, clientInit.random.count == 32 else {
            throw NearbyError.ukey2(reason: "Invalid version (\(clientInit.version)) or random size (\(clientInit.random.count))")
        }

        var foundCommitment: Data? = nil
        for commitment in clientInit.cipherCommitments {
            if case .p256Sha512 = commitment.handshakeCipher {
                foundCommitment = commitment.commitment
                break
            }
        }
        guard let commitment = foundCommitment else {
            throw NearbyError.ukey2(reason: "No p256Sha512 cipher commitment found")
        }
        self.cipherCommitment = commitment

        let privKey = P256.KeyAgreement.PrivateKey()
        let pubKey = privKey.publicKey
        self.privateKey = privKey
        self.publicKey = pubKey

        var serverInit = Securegcm_Ukey2ServerInit()
        serverInit.version = 1
        serverInit.random = Data.randomData(length: 32)
        serverInit.handshakeCipher = .p256Sha512

        let rawPub = Data(pubKey.rawRepresentation)
        var pkey = Securemessage_GenericPublicKey()
        pkey.type = .ecP256
        pkey.ecP256PublicKey = Securemessage_EcP256PublicKey()
        pkey.ecP256PublicKey.x = asSignedBigEndianBytes(Data(rawPub.prefix(32)))
        pkey.ecP256PublicKey.y = asSignedBigEndianBytes(Data(rawPub.suffix(32)))
        serverInit.publicKey = try pkey.serializedData()

        var serverInitMsg = Securegcm_Ukey2Message()
        serverInitMsg.messageType = .serverInit
        serverInitMsg.messageData = try serverInit.serializedData()
        let serverInitData = try serverInitMsg.serializedData()
        ukeyServerInitMsgData = serverInitData

        print("[InboundNearbyConnection] Sending UKEY2 serverInit...")
        sendFrameAsync(serverInitData)
        currentState = .sentUkeyServerInit
    }

    private func processUkey2ClientFinish(_ msg: Securegcm_Ukey2Message, raw: Data) throws {
        if msg.hasMessageType && msg.messageType == .alert {
            let alertType = (try? Securegcm_Ukey2Alert(serializedData: msg.messageData))?.type ?? .badMessage
            let alertErr = (try? Securegcm_Ukey2Alert(serializedData: msg.messageData))?.errorMessage ?? "no message"
            print("[InboundNearbyConnection] Android sent UKEY2 Alert: \(alertType) (\(alertErr))")
            throw NearbyError.ukey2(reason: "Android sent UKEY2 alert: \(alertType) (\(alertErr))")
        }

        guard msg.hasMessageType, msg.hasMessageData, case .clientFinish = msg.messageType else {
            throw NearbyError.ukey2(reason: "Expected clientFinish, received: \(msg.messageType)")
        }

        var shaRaw = SHA512()
        shaRaw.update(data: raw)
        let hashRaw = Data(shaRaw.finalize())

        var shaData = SHA512()
        shaData.update(data: msg.messageData)
        let hashData = Data(shaData.finalize())

        guard cipherCommitment == hashRaw || cipherCommitment == hashData else {
            print("[InboundNearbyConnection] Commitment mismatch! commitment=\(cipherCommitment?.hexEncodedString() ?? "nil") hashRaw=\(hashRaw.hexEncodedString()) hashData=\(hashData.hexEncodedString())")
            throw NearbyError.ukey2(reason: "Cipher commitment hash mismatch")
        }

        let clientFinish = try Securegcm_Ukey2ClientFinished(serializedData: msg.messageData)
        guard clientFinish.hasPublicKey else {
            throw NearbyError.requiredFieldMissing("clientFinish.publicKey")
        }
        let clientKey = try Securemessage_GenericPublicKey(serializedData: clientFinish.publicKey)
        print("[InboundNearbyConnection] UKEY2 clientFinish verified successfully, finalizing key exchange...")
        try finalizeKeyExchange(peerKey: clientKey)
        currentState = .receivedUkeyClientFinish
    }

    private func processConnectionResponseFrame(_ frame: Location_Nearby_Connections_OfflineFrame) throws {
        guard frame.hasV1, frame.v1.hasType, case .connectionResponse = frame.v1.type else {
            throw NearbyError.protocolError("Expected connectionResponse")
        }

        var resp = Location_Nearby_Connections_OfflineFrame()
        resp.version = .v1
        resp.v1 = Location_Nearby_Connections_V1Frame()
        resp.v1.type = .connectionResponse
        resp.v1.connectionResponse = Location_Nearby_Connections_ConnectionResponseFrame()
        resp.v1.connectionResponse.response = .accept
        resp.v1.connectionResponse.status = 0
        resp.v1.connectionResponse.osInfo = Location_Nearby_Connections_OsInfo()
        resp.v1.connectionResponse.osInfo.type = .apple
        sendFrameAsync(try resp.serializedData())

        encryptionDone = true

        var pairedEncryption = Sharing_Nearby_Frame()
        pairedEncryption.version = .v1
        pairedEncryption.v1 = Sharing_Nearby_V1Frame()
        pairedEncryption.v1.type = .pairedKeyEncryption
        pairedEncryption.v1.pairedKeyEncryption = Sharing_Nearby_PairedKeyEncryptionFrame()
        pairedEncryption.v1.pairedKeyEncryption.secretIDHash = Data.randomData(length: 6)
        pairedEncryption.v1.pairedKeyEncryption.signedData = Data.randomData(length: 72)
        try sendTransferSetupFrame(pairedEncryption)
        currentState = .sentConnectionResponse
    }

    private func processPairedKeyEncryptionFrame(_ frame: Sharing_Nearby_Frame) throws {
        guard frame.hasV1, frame.v1.hasPairedKeyEncryption else {
            throw NearbyError.requiredFieldMissing("pairedKeyEncryption")
        }
        var pairedResult = Sharing_Nearby_Frame()
        pairedResult.version = .v1
        pairedResult.v1 = Sharing_Nearby_V1Frame()
        pairedResult.v1.type = .pairedKeyResult
        pairedResult.v1.pairedKeyResult = Sharing_Nearby_PairedKeyResultFrame()
        pairedResult.v1.pairedKeyResult.status = .unable
        try sendTransferSetupFrame(pairedResult)
        currentState = .sentPairedKeyResult
    }

    private func processPairedKeyResultFrame(_ frame: Sharing_Nearby_Frame) throws {
        guard frame.hasV1, frame.v1.hasPairedKeyResult else {
            throw NearbyError.requiredFieldMissing("pairedKeyResult")
        }
        currentState = .receivedPairedKeyResult
    }

    private func processIntroductionFrame(_ frame: Sharing_Nearby_Frame) throws {
        guard frame.hasV1, frame.v1.hasIntroduction else {
            throw NearbyError.requiredFieldMissing("introduction")
        }
        currentState = .waitingForUserConsent

        let downloadsDir = (try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )).resolvingSymlinksInPath()

        var files = [FileMetadata]()
        for file in frame.v1.introduction.fileMetadata {
            let meta = FileMetadata(id: file.payloadID, name: file.name, size: file.size, mimeType: file.mimeType)
            files.append(meta)
            let writer = try StreamingFileWriter(metadata: meta, destinationDirectory: downloadsDir)
            writer.delegate = self
            fileWriters[file.payloadID] = writer
        }

        let metadata = TransferMetadata(
            id: id,
            files: files,
            pinCode: pinCode,
            sender: remoteDeviceInfo ?? RemoteDeviceInfo(name: "Android Phone", type: .phone)
        )
        self.transferMetadata = metadata

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.obtainUserConsent(for: metadata, from: metadata.sender, connection: self)
        }
    }

    public func submitUserConsent(accepted: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            if accepted {
                self.acceptTransfer()
            } else {
                self.rejectTransfer()
            }
        }
    }

    private func acceptTransfer() {
        do {
            SleepAssertionManager.shared.beginActivity()
            isSleepingAssertionActive = true

            var frame = Sharing_Nearby_Frame()
            frame.version = .v1
            frame.v1.type = .response
            frame.v1.connectionResponse.status = .accept
            currentState = .receivingFiles
            try sendTransferSetupFrame(frame)
        } catch {
            lastError = error
            protocolError()
        }
    }

    private func rejectTransfer() {
        var frame = Sharing_Nearby_Frame()
        frame.version = .v1
        frame.v1.type = .response
        frame.v1.connectionResponse.status = .reject
        do {
            try sendTransferSetupFrame(frame)
            try sendDisconnectionAndDisconnect()
        } catch {
            protocolError()
        }
    }
}
