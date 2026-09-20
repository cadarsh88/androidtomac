import Foundation

public struct RemoteDeviceInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: DeviceType
    public let qrCodeData: Data?

    public init(name: String, type: DeviceType, id: String = UUID().uuidString, qrCodeData: Data? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.qrCodeData = qrCodeData
    }

    public enum DeviceType: Int32, Sendable, Equatable {
        case unknown = 0
        case phone = 1
        case tablet = 2
        case computer = 3

        public static func fromRawValue(value: Int) -> DeviceType {
            switch value {
            case 1: return .phone
            case 2: return .tablet
            case 3: return .computer
            default: return .unknown
            }
        }

        public var systemImageName: String {
            switch self {
            case .phone: return "iphone"
            case .tablet: return "ipad"
            case .computer: return "laptopcomputer"
            case .unknown: return "questionmark.circle"
            }
        }
    }
}
