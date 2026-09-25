import Cocoa
import Quartz
import UniformTypeIdentifiers

/// Space-bar preview for .eps files (data-based Quick Look preview).
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let result = try EPSDecoder.decode(url: request.fileURL)
        let image = result.image

        // Photos as JPEG (small, fast), line art / previews as PNG (crisp).
        guard let data = EPSDecoder.encode(image, jpeg: result.isPhoto) else {
            throw EPSDecodeError.noImage
        }
        let type: UTType = result.isPhoto ? .jpeg : .png

        // Initial window size: fit a generous box, enlarging small (72 ppi)
        // previews up to 2x. Quick Look shrinks it further if the screen is smaller.
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(2, 1400 / w, 1000 / h)
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))

        return QLPreviewReply(dataOfContentType: type, contentSize: size) { _ in data }
    }
}
