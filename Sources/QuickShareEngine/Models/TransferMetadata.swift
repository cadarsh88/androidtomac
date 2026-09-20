import Foundation

public struct FileMetadata: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let size: Int64
    public let mimeType: String

    public init(id: Int64, name: String, size: Int64, mimeType: String) {
        self.id = id
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

public struct TransferMetadata: Identifiable, Sendable, Equatable {
    public let id: String
    public let files: [FileMetadata]
    public let pinCode: String?
    public let sender: RemoteDeviceInfo

    public init(id: String, files: [FileMetadata], pinCode: String?, sender: RemoteDeviceInfo) {
        self.id = id
        self.files = files
        self.pinCode = pinCode
        self.sender = sender
    }

    public var totalSize: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    public var formattedTotalSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}

public enum TransferStatus: Equatable, Sendable {
    case idle
    case waitingForConsent(TransferMetadata)
    case transferring(TransferProgress)
    case completed(String)
    case failed(String)
    case cancelled
}

public struct TransferProgress: Sendable, Equatable {
    public let transferredBytes: Int64
    public let totalBytes: Int64
    public let speedBytesPerSec: Double
    public let currentFileName: String

    public init(transferredBytes: Int64, totalBytes: Int64, speedBytesPerSec: Double, currentFileName: String) {
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSec = speedBytesPerSec
        self.currentFileName = currentFileName
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, Double(transferredBytes) / Double(totalBytes))
    }

    public var formattedSpeed: String {
        let mbps = speedBytesPerSec / (1024.0 * 1024.0)
        return String(format: "%.1f MB/s", mbps)
    }

    public var estimatedTimeRemaining: String {
        guard speedBytesPerSec > 1024 else { return "Calculating..." }
        let remainingBytes = max(0, totalBytes - transferredBytes)
        let seconds = Double(remainingBytes) / speedBytesPerSec
        if seconds < 60 {
            return String(format: "%.0fs remaining", seconds)
        } else {
            let minutes = Int(seconds) / 60
            let remSecs = Int(seconds) % 60
            return "\(minutes)m \(remSecs)s remaining"
        }
    }
}
