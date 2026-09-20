import Foundation

public struct EndpointInfo: Sendable {
    public var name: String?
    public let deviceType: RemoteDeviceInfo.DeviceType
    public let qrCodeData: Data?

    public init(name: String, deviceType: RemoteDeviceInfo.DeviceType, qrCodeData: Data? = nil) {
        self.name = name
        self.deviceType = deviceType
        self.qrCodeData = qrCodeData
    }

    public init?(data: Data) {
        guard data.count > 17 else { return nil }
        let hasName = (data[0] & 0x10) == 0
        let deviceNameLength: Int
        let deviceName: String?

        if hasName {
            deviceNameLength = Int(data[17])
            guard data.count >= deviceNameLength + 18 else { return nil }
            guard let decodedName = String(data: data[18..<(18 + deviceNameLength)], encoding: .utf8) else {
                return nil
            }
            deviceName = decodedName
        } else {
            deviceNameLength = 0
            deviceName = nil
        }

        let rawDeviceType = Int(data[0] & 7) >> 1
        self.name = deviceName
        self.deviceType = RemoteDeviceInfo.DeviceType.fromRawValue(value: rawDeviceType)

        var offset = 1 + 16
        if hasName {
            offset += 1 + deviceNameLength
        }

        var qrCode: Data? = nil
        while data.count - offset > 2 {
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            if data.count - offset >= length {
                if type == 1 {
                    qrCode = data.subdata(in: offset..<(offset + length))
                }
                offset += length
            }
        }
        self.qrCodeData = qrCode
    }

    public func serialize() -> Data {
        var endpointInfo = [UInt8]()
        // 1 byte: Version(3 bits) | Visibility(1 bit: 0=visible) | Device Type(3 bits) | Reserved(1 bit)
        endpointInfo.append(UInt8(deviceType.rawValue << 1))

        // 16 bytes: random salt / metadata
        for _ in 0..<16 {
            endpointInfo.append(UInt8.random(in: 0...255))
        }

        // Device name in UTF-8 prefixed with 1-byte length
        let safeName = name ?? "Mac"
        var nameChars = [UInt8](safeName.utf8)
        if nameChars.count > 255 {
            nameChars = Array(nameChars[0..<255])
        }
        endpointInfo.append(UInt8(nameChars.count))
        endpointInfo.append(contentsOf: nameChars)

        return Data(endpointInfo)
    }
}
