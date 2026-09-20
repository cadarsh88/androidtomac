import Foundation
import CryptoKit
import QuickShareEngine

@main
struct TestRunner {
    static func main() throws {
        print("=========================================")
        print("  QuickShareEngine Unit Test Suite")
        print("=========================================")

        // 1. Test PIN Code Generation
        print("[*] TEST 1: UKEY2 4-Digit Auth PIN Derivation...")
        let authKeyBytes = [UInt8](repeating: 0x42, count: 32)
        let authKey = SymmetricKey(data: authKeyBytes)
        let pin = NearbyConnection.pinCodeFromAuthKey(authKey)
        assert(pin.count == 4, "PIN code must always be exactly 4 digits")
        assert(Int(pin) != nil, "PIN code must be numeric")
        print("    [PASS] PIN code computed: \(pin)")

        // 2. Test EndpointInfo Serialization
        print("[*] TEST 2: EndpointInfo Serialization / Deserialization...")
        let originalName = "Adarsh MacBook Pro"
        let endpoint = EndpointInfo(name: originalName, deviceType: .computer)
        let serialized = endpoint.serialize()
        assert(serialized.count > 18, "Serialized data must be > 18 bytes")

        let deserialized = EndpointInfo(data: serialized)
        assert(deserialized != nil, "Deserialization must succeed")
        assert(deserialized?.name == originalName, "Device name must match")
        assert(deserialized?.deviceType == .computer, "Device type must match")
        print("    [PASS] Endpoint parsed correctly (Name: \(deserialized?.name ?? ""), Type: \(deserialized?.deviceType ?? .unknown))")

        // 3. Test StreamingFileWriter Chunks & Atomic Move
        print("[*] TEST 3: StreamingFileWriter Direct Disk Stream & Atomic Move...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestStreamWriter_\(UUID().uuidString)")
        let sampleData = "Quick Share 1-3GB high-bandwidth streaming test verification payload".data(using: .utf8)!
        let meta = FileMetadata(id: 777, name: "sample_test.txt", size: Int64(sampleData.count), mimeType: "text/plain")

        let writer = try StreamingFileWriter(metadata: meta, destinationDirectory: tempDir)
        try writer.writeChunk(sampleData, offset: 0)

        let finalURL = try writer.finalizeTransfer()
        assert(FileManager.default.fileExists(atPath: finalURL.path), "Final file must exist")

        let readBack = try Data(contentsOf: finalURL)
        assert(readBack == sampleData, "File content on disk must match written chunk")
        try? FileManager.default.removeItem(at: tempDir)
        print("    [PASS] Chunk written, verified, and atomically finalized at: \(finalURL.lastPathComponent)")

        print("\n=========================================")
        print("  ALL 3 TEST SUITES PASSED (100% OK)")
        print("=========================================\n")
    }
}
