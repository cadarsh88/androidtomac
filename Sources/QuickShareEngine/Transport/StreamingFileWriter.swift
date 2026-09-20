import Foundation

public protocol StreamingFileWriterDelegate: AnyObject {
    func fileWriterDidUpdateProgress(_ writer: StreamingFileWriter, progress: TransferProgress)
    func fileWriterDidFinish(_ writer: StreamingFileWriter, finalURL: URL)
    func fileWriterDidFail(_ writer: StreamingFileWriter, error: Error)
}

public final class StreamingFileWriter: @unchecked Sendable {
    public let metadata: FileMetadata
    public let destinationDirectory: URL
    public let temporaryURL: URL
    public let finalURL: URL

    private var fileHandle: FileHandle?
    private var bytesWritten: Int64 = 0
    private var lastSampleTime: Date = Date()
    private var lastSampleBytes: Int64 = 0
    private var currentSpeed: Double = 0.0
    private let speedSmoothingFactor: Double = 0.7

    public weak var delegate: StreamingFileWriterDelegate?

    public init(metadata: FileMetadata, destinationDirectory: URL) throws {
        self.metadata = metadata
        self.destinationDirectory = destinationDirectory

        let targetFilename = StreamingFileWriter.resolveUniqueFilename(
            directory: destinationDirectory,
            baseName: metadata.name
        )
        self.finalURL = destinationDirectory.appendingPathComponent(targetFilename)
        self.temporaryURL = destinationDirectory.appendingPathComponent(".\(targetFilename).download")

        // Ensure parent directory exists
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        // Create empty temporary file
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: temporaryURL)
        self.lastSampleTime = Date()
        self.lastSampleBytes = 0
    }

    public func writeChunk(_ data: Data, offset: Int64) throws {
        guard let handle = fileHandle else {
            throw NSError(domain: "StreamingFileWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "File handle is closed"])
        }
        guard offset == bytesWritten else {
            throw NSError(domain: "StreamingFileWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Chunk offset mismatch: expected \(bytesWritten), got \(offset)"])
        }

        try handle.write(contentsOf: data)
        bytesWritten += Int64(data.count)

        // Speed calculation
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        if elapsed >= 0.25 {
            let bytesDelta = bytesWritten - lastSampleBytes
            let instantSpeed = Double(bytesDelta) / elapsed
            currentSpeed = (currentSpeed * (1.0 - speedSmoothingFactor)) + (instantSpeed * speedSmoothingFactor)
            lastSampleTime = now
            lastSampleBytes = bytesWritten

            let progress = TransferProgress(
                transferredBytes: bytesWritten,
                totalBytes: metadata.size,
                speedBytesPerSec: currentSpeed,
                currentFileName: metadata.name
            )
            delegate?.fileWriterDidUpdateProgress(self, progress: progress)
        }
    }

    public func finalizeTransfer() throws -> URL {
        guard let handle = fileHandle else {
            throw NSError(domain: "StreamingFileWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "File handle already finalized"])
        }

        try handle.close()
        self.fileHandle = nil

        // Verify total bytes written matches metadata
        if metadata.size > 0 && bytesWritten != metadata.size {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw NSError(domain: "StreamingFileWriter", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Incomplete file transfer: expected \(metadata.size) bytes, received \(bytesWritten)"
            ])
        }

        // Atomically rename temporary file to destination
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        delegate?.fileWriterDidFinish(self, finalURL: finalURL)
        return finalURL
    }

    public func abort() {
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private static func resolveUniqueFilename(directory: URL, baseName: String) -> String {
        let destinationPath = directory.appendingPathComponent(baseName).path
        if !FileManager.default.fileExists(atPath: destinationPath) {
            return baseName
        }

        let ext = (baseName as NSString).pathExtension
        let nameWithoutExt = (baseName as NSString).deletingPathExtension

        var counter = 1
        var candidateName: String
        repeat {
            if ext.isEmpty {
                candidateName = "\(nameWithoutExt) (\(counter))"
            } else {
                candidateName = "\(nameWithoutExt) (\(counter)).\(ext)"
            }
            counter += 1
        } while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidateName).path)

        return candidateName
    }
}
