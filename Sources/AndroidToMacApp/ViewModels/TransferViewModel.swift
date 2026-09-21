import Foundation
import Combine
import SwiftUI
import QuickShareEngine

public struct CompletedTransferRecord: Identifiable, Sendable {
    public let id: String
    public let senderName: String
    public let fileNames: [String]
    public let totalSize: Int64
    public let savedURLs: [URL]
    public let timestamp: Date

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}

@MainActor
public final class TransferViewModel: ObservableObject, QuickShareServerDelegate {
    @Published public var isRunning: Bool = false
    @Published public var listeningPort: UInt16 = 0
    @Published public var endpointID: String = ""
    @Published public var customDeviceName: String = Host.current().localizedName ?? "Mac"

    @Published public var activeTransfer: TransferMetadata?
    @Published public var currentProgress: TransferProgress?
    @Published public var currentStatus: String = "Ready for Quick Share"
    @Published public var transferHistory: [CompletedTransferRecord] = []
    @Published public var showQRCode: Bool = false
    @Published public var pairingQRCodeImage: NSImage?

    public var localIPAddress: String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let interface = ptr!.pointee
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        break
                    }
                }
                ptr = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private var activeConnection: InboundNearbyConnection?

    public init() {
        QuickShareServer.shared.delegate = self
        startServer()
    }

    public func startServer() {
        do {
            QuickShareServer.shared.customDeviceName = customDeviceName
            try QuickShareServer.shared.start()
            isRunning = true
            currentStatus = "Discoverable on Wi-Fi"
        } catch {
            currentStatus = "Server error: \(error.localizedDescription)"
            isRunning = false
        }
    }

    public func stopServer() {
        QuickShareServer.shared.stop()
        isRunning = false
        currentStatus = "Offline"
    }

    public func acceptTransfer() {
        guard let transfer = activeTransfer else { return }
        QuickShareServer.shared.submitConsent(transferID: transfer.id, accept: true)
        currentStatus = "Transferring..."
    }

    public func declineTransfer() {
        guard let transfer = activeTransfer else { return }
        QuickShareServer.shared.submitConsent(transferID: transfer.id, accept: false)
        activeTransfer = nil
        currentProgress = nil
        currentStatus = "Declined transfer"
    }

    public func cancelTransfer() {
        activeConnection?.disconnect()
        activeTransfer = nil
        currentProgress = nil
        currentStatus = "Cancelled transfer"
    }

    public func toggleQRCode() {
        showQRCode.toggle()
        if showQRCode {
            let dropURL = "http://\(localIPAddress):\(listeningPort)"
            pairingQRCodeImage = QRCodeGenerator.generateQRCode(from: dropURL, scale: 6.0)
        }
    }

    // MARK: - QuickShareServerDelegate

    public func serverDidStart(port: UInt16, endpointID: String) {
        self.listeningPort = port
        self.endpointID = endpointID
        self.isRunning = true
        self.currentStatus = "Discoverable on Wi-Fi"
    }

    public func serverDidFail(error: Error) {
        self.isRunning = false
        self.currentStatus = "Failed: \(error.localizedDescription)"
    }

    public func serverDidReceiveTransferRequest(transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
        self.activeTransfer = transfer
        self.activeConnection = connection
        self.currentStatus = "Incoming transfer from \(device.name)"

        // Send native macOS notification
        NotificationHelper.sendNotification(
            title: "Quick Share from \(device.name)",
            body: "\(transfer.files.count) files (\(transfer.formattedTotalSize)). PIN: \(transfer.pinCode ?? "----")"
        )
    }

    public func serverTransferProgressUpdated(connection: InboundNearbyConnection, progress: TransferProgress) {
        self.currentProgress = progress
        self.currentStatus = "Receiving: \(progress.formattedSpeed)"
    }

    public func serverTransferCompleted(connection: InboundNearbyConnection, savedURLs: [URL]) {
        if let transfer = activeTransfer {
            let record = CompletedTransferRecord(
                id: transfer.id,
                senderName: transfer.sender.name,
                fileNames: transfer.files.map(\.name),
                totalSize: transfer.totalSize,
                savedURLs: savedURLs,
                timestamp: Date()
            )
            transferHistory.insert(record, at: 0)
        }
        self.activeTransfer = nil
        self.currentProgress = nil
        self.activeConnection = nil
        self.currentStatus = "Transfer completed successfully"

        NotificationHelper.sendNotification(
            title: "Transfer Complete",
            body: "Saved to Downloads folder."
        )
    }

    public func serverTransferTerminated(connection: InboundNearbyConnection, error: Error?) {
        self.activeTransfer = nil
        self.currentProgress = nil
        self.activeConnection = nil
        if let error = error {
            self.currentStatus = "Transfer failed: \(error.localizedDescription)"
        } else {
            self.currentStatus = "Ready for Quick Share"
        }
    }
}

public struct NotificationHelper {
    public static func sendNotification(title: String, body: String) {
        let center = NSUserNotificationCenter.default
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        center.deliver(notification)
    }
}
