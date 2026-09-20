import Foundation
import CryptoKit

public extension SymmetricKey {
    func data() -> Data {
        return withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
    }
}
