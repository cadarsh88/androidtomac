import Foundation
import CoreImage
import AppKit

public struct QRCodeGenerator {
    public static func generateQRCode(from string: String, scale: CGFloat = 8.0) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        guard let data = string.data(using: .utf8) else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let transformedImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: transformedImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    public static func quickSharePairingURL(publicKeyData: Data) -> String {
        let base64Key = publicKeyData.urlSafeBase64EncodedString()
        return "https://quickshare.google/qrcode#key=\(base64Key)"
    }
}
