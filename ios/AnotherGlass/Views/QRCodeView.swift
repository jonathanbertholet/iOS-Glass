import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let value: String
    private static let context = CIContext()

    var body: some View {
        Group {
            if let image = makeImage() {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            } else {
                Label("Could not create QR code", systemImage: "qrcode")
            }
        }
    }

    private func makeImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = Self.context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
