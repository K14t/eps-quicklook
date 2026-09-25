import Foundation
import CoreGraphics
import QuickLookThumbnailing

/// Finder icons / thumbnails for .eps files.
class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let result = try EPSDecoder.decode(url: request.fileURL)
            let maxPixels = Int(max(request.maximumSize.width, request.maximumSize.height) * max(request.scale, 1))
            let image = EPSDecoder.renderRGB(result.image, maxPixelSize: maxPixels) ?? result.image

            let w = CGFloat(image.width), h = CGFloat(image.height)
            let fit = min(request.maximumSize.width / w, request.maximumSize.height / h)
            let size = CGSize(width: max(1, (w * fit).rounded()), height: max(1, (h * fit).rounded()))

            let reply = QLThumbnailReply(contextSize: size, drawing: { context -> Bool in
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(origin: .zero, size: size))
                return true
            })
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
