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

        // Initial window size; the full-resolution image is still available for zooming.
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let maxSide: CGFloat = 900
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: max(1, w * scale), height: max(1, h * scale))

        return QLPreviewReply(dataOfContentType: type, contentSize: size) { _ in data }
    }
}
