import Foundation
import CoreGraphics
import ImageIO

/// Result of decoding an EPS file into something we can draw.
struct EPSDecodedImage {
    /// The image, always converted to sRGB on a white background.
    let image: CGImage
    /// Which strategy produced the image (for diagnostics / tests).
    let method: String
    /// True for photographic content (JPEG is a better preview encoding than PNG).
    let isPhoto: Bool
}

enum EPSDecodeError: Error, LocalizedError {
    case unreadable
    case noImage

    var errorDescription: String? {
        switch self {
        case .unreadable: return "EPS ファイルを読み込めませんでした。"
        case .noImage: return "この EPS にはプレビューできる画像が含まれていません。"
        }
    }
}

/// Decodes EPS files WITHOUT a PostScript interpreter. No code in the file is
/// ever executed; we only pull image data out of well-known structures:
///
///  1. Photoshop EPS  – the real pixel data announced by `%ImageData:`
///                      (JPEG / binary / ASCII-hex / ASCII85).
///  2. DOS EPS header – the TIFF preview Photoshop / Illustrator embed.
///  3. XMP            – the `<xmpGImg:image>` JPEG thumbnail Illustrator writes.
enum EPSDecoder {

    static func decode(url: URL) throws -> EPSDecodedImage {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw EPSDecodeError.unreadable
        }
        return try decode(data: data)
    }

    static func decode(data: Data) throws -> EPSDecodedImage {
        let bytes = [UInt8](data)
        guard bytes.count > 16 else { throw EPSDecodeError.unreadable }

        var psRange = 0..<bytes.count
        var tiffRange: Range<Int>? = nil

        // DOS EPS binary header: C5 D0 D3 C6, then little-endian offsets.
        if bytes[0] == 0xC5 && bytes[1] == 0xD0 && bytes[2] == 0xD3 && bytes[3] == 0xC6 && bytes.count >= 30 {
            let psStart = readLE32(bytes, 4), psLen = readLE32(bytes, 8)
            let tStart = readLE32(bytes, 20), tLen = readLE32(bytes, 24)
            if psStart < bytes.count {
                psRange = psStart..<min(bytes.count, psStart + psLen)
            }
            if tLen > 8 && tStart < bytes.count && tStart + tLen <= bytes.count {
                tiffRange = tStart..<(tStart + tLen)
            }
        }

        // 1. Real image inside a Photoshop EPS (best quality).
        if let result = PhotoshopImage.decode(bytes, ps: psRange) {
            return result
        }
        // 2. Embedded TIFF preview.
        if let r = tiffRange, let img = TIFFPreview.decode(bytes, range: r), let rgb = renderRGB(img) {
            return EPSDecodedImage(image: rgb, method: "tiff-preview", isPhoto: false)
        }
        // 3. XMP thumbnail.
        if let img = XMPThumbnail.decode(bytes, ps: psRange), let rgb = renderRGB(img) {
            return EPSDecodedImage(image: rgb, method: "xmp-thumbnail", isPhoto: true)
        }
        throw EPSDecodeError.noImage
    }

    // MARK: - Rendering helpers

    /// Draws `image` into an opaque sRGB bitmap on white, optionally downscaled.
    static func renderRGB(_ image: CGImage, maxPixelSize: Int? = nil) -> CGImage? {
        var w = image.width, h = image.height
        if let m = maxPixelSize, m > 0, max(w, h) > m {
            let s = Double(m) / Double(max(w, h))
            w = max(1, Int((Double(w) * s).rounded()))
            h = max(1, Int((Double(h) * s).rounded()))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Returns a copy of `image` whose colour components are inverted, by
    /// flipping the CGImage decode array (no pixel copying). Images with alpha
    /// are flattened to RGB first.
    static func invertComponents(_ image: CGImage) -> CGImage? {
        var source = image
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst:
            break
        default:
            guard let flat = renderRGB(image) else { return nil }
            source = flat
        }
        guard let space = source.colorSpace, let provider = source.dataProvider else { return nil }
        let n = space.numberOfComponents
        var decode = [CGFloat]()
        if let old = source.decode {
            for i in 0..<n { decode.append(old[2 * i + 1]); decode.append(old[2 * i]) }
        } else {
            for _ in 0..<n { decode.append(1); decode.append(0) }
        }
        return CGImage(width: source.width, height: source.height,
                       bitsPerComponent: source.bitsPerComponent, bitsPerPixel: source.bitsPerPixel,
                       bytesPerRow: source.bytesPerRow, space: space, bitmapInfo: source.bitmapInfo,
                       provider: provider, decode: decode, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    static func imageFromData(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Encodes an image as PNG or JPEG data.
    static func encode(_ image: CGImage, jpeg: Bool) -> Data? {
        let data = NSMutableData()
        let type = (jpeg ? "public.jpeg" : "public.png") as CFString
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else { return nil }
        let props: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Reads one pixel of an image as sRGB (x, y from the top-left). Used for
    /// the ImageIO calibration below and by the test tool.
    static func samplePixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        guard let p = ctx.data?.bindMemory(to: UInt8.self, capacity: 4) else { return nil }
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    // MARK: - CMYK JPEG polarity calibration

    /// Photoshop EPS stores JPEG CMYK samples in PostScript polarity (0 = no
    /// ink) but still tags them with an Adobe APP14 marker, which normally means
    /// "inverted". Whether ImageIO flips such data is decided here at runtime:
    /// we decode a tiny JPEG whose stored samples are all 0 (= white in
    /// PostScript) and see what comes out.
    static let imageIOInvertsEPSCMYK: Bool = {
        guard let data = Data(base64Encoded: calibrationJPEG),
              let img = imageFromData(data),
              let px = samplePixel(img, x: 4, y: 4)
        else { return true }
        return (px.r + px.g + px.b) / 3 < 128
    }()

    private static let calibrationJPEG =
        "/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/8AAFAgACAAIBEMRAE0RAFkRAEsRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAA4EQwBNAFkASwAAPwD8qq/Kqvyqr8qq/9k="
}

// MARK: - Byte utilities

@inline(__always)
func readLE32(_ b: [UInt8], _ o: Int) -> Int {
    guard o + 4 <= b.count else { return 0 }
    return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
}

/// Naive byte-pattern search in `hay[from..<to]`.
func findBytes(_ hay: [UInt8], _ needle: [UInt8], from: Int, to: Int) -> Int? {
    let n = needle.count
    let end = min(to, hay.count)
    guard n > 0, from >= 0, end - from >= n else { return nil }
    let first = needle[0]
    let last = end - n
    return hay.withUnsafeBufferPointer { h -> Int? in
        needle.withUnsafeBufferPointer { nd -> Int? in
            var i = from
            while i <= last {
                if h[i] == first {
                    var j = 1
                    while j < n && h[i + j] == nd[j] { j += 1 }
                    if j == n { return i }
                }
                i += 1
            }
            return nil
        }
    }
}

func latin1(_ b: [UInt8], _ r: Range<Int>) -> String {
    let lo = max(0, r.lowerBound), hi = min(b.count, r.upperBound)
    guard lo < hi else { return "" }
    return String(bytes: b[lo..<hi], encoding: .isoLatin1) ?? ""
}

@inline(__always)
func isEOL(_ c: UInt8) -> Bool { c == 0x0A || c == 0x0D }

// MARK: - 1. Photoshop EPS

enum PhotoshopImage {

    static func decode(_ b: [UInt8], ps: Range<Int>) -> EPSDecodedImage? {
        let head = latin1(b, ps.lowerBound..<min(ps.upperBound, ps.lowerBound + 8192))
        guard head.contains("%%Creator: Adobe Photoshop") else { return nil }

        let tag = Array("%ImageData:".utf8)
        guard let idPos = findBytes(b, tag, from: ps.lowerBound,
                                    to: min(ps.upperBound, ps.lowerBound + 4_000_000)) else { return nil }
        var lineEnd = idPos
        while lineEnd < ps.upperBound && !isEOL(b[lineEnd]) { lineEnd += 1 }

        // %ImageData: cols rows depth mode padChannels blockSize encoding "marker"
        let fields = latin1(b, (idPos + tag.count)..<lineEnd).split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 8,
              let cols = Int(fields[0]), let rows = Int(fields[1]),
              let depth = Int(fields[2]), let mode = Int(fields[3]),
              let pad = Int(fields[4]), let blockSize = Int(fields[5]), let encoding = Int(fields[6]),
              cols > 0, rows > 0, cols * rows < 400_000_000
        else { return nil }
        let marker = fields[7...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !marker.isEmpty else { return nil }

        // The data starts on the line after the marker, which sits on a line of its own.
        let mBytes = Array(marker.utf8)
        var search = lineEnd
        var dataStart: Int? = nil
        while let p = findBytes(b, mBytes, from: search, to: ps.upperBound) {
            let after = p + mBytes.count
            if p > 0, isEOL(b[p - 1]), after < ps.upperBound, isEOL(b[after]) {
                var s = after
                if b[s] == 0x0D { s += 1 }
                if s < ps.upperBound && b[s] == 0x0A { s += 1 }
                dataStart = s
                break
            }
            search = p + 1
        }
        guard let ds = dataStart else { return nil }

        let setup = latin1(b, idPos..<ds)
        let isA85 = setup.contains("ASCII85Decode")
        let isDCT = setup.contains("DCTDecode")
        let isHex = setup.contains("ASCIIHexDecode") || (!isA85 && encoding == 2)
        let decodeInverted = setup.replacingOccurrences(of: " ", with: "").contains("/Decode[10")

        let channels: Int
        switch mode {
        case 1: channels = 1      // grayscale (and bitmap, rejected below via depth)
        case 3: channels = 3      // RGB
        case 4: channels = 4      // CMYK
        default: return nil       // Lab / multichannel: fall back to the preview
        }
        let rawCount = cols * rows * channels

        // Undo the transport encoding.
        let payload: [UInt8]
        if isA85 {
            guard let d = ascii85Decode(b, from: ds, to: ps.upperBound) else { return nil }
            payload = d
        } else if isHex {
            payload = hexDecode(b, from: ds, to: ps.upperBound, limit: isDCT ? Int.max : rawCount)
        } else if isDCT {
            let end = findBytes(b, Array("%%EndBinary".utf8), from: ds, to: ps.upperBound) ?? ps.upperBound
            payload = Array(b[ds..<end])
        } else {
            guard ds + rawCount <= ps.upperBound else { return nil }
            payload = Array(b[ds..<(ds + rawCount)])
        }

        var image: CGImage?
        if isDCT {
            guard var img = EPSDecoder.imageFromData(Data(payload)) else { return nil }
            let isCMYK = img.colorSpace?.model == .cmyk || channels == 4
            // Work out whether the colours need flipping (see calibration notes).
            var flip = decodeInverted
            if isCMYK && EPSDecoder.imageIOInvertsEPSCMYK { flip.toggle() }
            if flip, let inv = EPSDecoder.invertComponents(img) { img = inv }
            image = img
        } else {
            guard depth == 8, pad == 0, payload.count >= rawCount else { return nil }
            var px = Array(payload[0..<rawCount])
            // blockSize == 1: pixel-interleaved. blockSize == cols: each row
            // stores one plane per channel; interleave it.
            if channels > 1 && blockSize == cols && blockSize != 1 {
                var inter = [UInt8](repeating: 0, count: rawCount)
                for y in 0..<rows {
                    let rowBase = y * cols * channels
                    for c in 0..<channels {
                        for x in 0..<cols {
                            inter[rowBase + x * channels + c] = px[rowBase + c * cols + x]
                        }
                    }
                }
                px = inter
            } else if channels > 1 && blockSize != 1 {
                return nil
            }
            if decodeInverted { for i in px.indices { px[i] = 255 &- px[i] } }
            image = makeImage(px, width: cols, height: rows, channels: channels)
        }

        guard let decoded = image, let rgb = EPSDecoder.renderRGB(decoded) else { return nil }
        return EPSDecodedImage(image: rgb, method: isDCT ? "photoshop-jpeg" : "photoshop-raw", isPhoto: true)
    }

    static func makeImage(_ px: [UInt8], width: Int, height: Int, channels: Int) -> CGImage? {
        let spaceName: CFString
        switch channels {
        case 1: spaceName = CGColorSpace.genericGrayGamma2_2
        case 3: spaceName = CGColorSpace.sRGB
        default: spaceName = CGColorSpace.genericCMYK
        }
        guard let space = CGColorSpace(name: spaceName),
              let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                       bytesPerRow: width * channels, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// ASCII85 (btoa) decoding, stopping at "~>".
    static func ascii85Decode(_ b: [UInt8], from: Int, to: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(max(0, (to - from) * 4 / 5))
        var group = [UInt64](repeating: 0, count: 5)
        var n = 0
        var i = from
        let end = min(to, b.count)
        while i < end {
            let c = b[i]
            i += 1
            if c == 0x7E { break }                 // '~'
            if c <= 0x20 { continue }              // whitespace
            if c == 0x7A && n == 0 {               // 'z'
                out.append(contentsOf: [0, 0, 0, 0])
                continue
            }
            guard c >= 0x21 && c <= 0x75 else { return nil }
            group[n] = UInt64(c - 0x21)
            n += 1
            if n == 5 {
                var v: UInt64 = 0
                for k in 0..<5 { v = v * 85 + group[k] }
                guard v <= 0xFFFF_FFFF else { return nil }
                out.append(UInt8((v >> 24) & 0xFF))
                out.append(UInt8((v >> 16) & 0xFF))
                out.append(UInt8((v >> 8) & 0xFF))
                out.append(UInt8(v & 0xFF))
                n = 0
            }
        }
        if n > 1 {
            for k in n..<5 { group[k] = 84 }
            var v: UInt64 = 0
            for k in 0..<5 { v = v * 85 + group[k] }
            let four: [UInt8] = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                                 UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            out.append(contentsOf: four[0..<(n - 1)])
        }
        return out
    }

    /// ASCII-hex decoding, stopping at '>', a non-hex character or `limit` bytes.
    static func hexDecode(_ b: [UInt8], from: Int, to: Int, limit: Int) -> [UInt8] {
        var out = [UInt8]()
        var hi: UInt8? = nil
        var i = from
        let end = min(to, b.count)
        while i < end && out.count < limit {
            let c = b[i]
            i += 1
            let v: UInt8
            switch c {
            case 0x30...0x39: v = c - 0x30
            case 0x41...0x46: v = c - 0x41 + 10
            case 0x61...0x66: v = c - 0x61 + 10
            case 0x09, 0x0A, 0x0C, 0x0D, 0x20: continue
            default: i = end; continue
            }
            if let h = hi {
                out.append(h << 4 | v)
                hi = nil
            } else {
                hi = v
            }
        }
        return out
    }
}

// MARK: - 2. TIFF preview

enum TIFFPreview {

    static func decode(_ b: [UInt8], range: Range<Int>) -> CGImage? {
        let t = Array(b[range])
        if let img = decodeSimple(t) { return img }
        // Anything our small reader does not handle: let ImageIO try.
        return EPSDecoder.imageFromData(Data(t))
    }

    /// Handles the uncompressed palette / gray / RGB / 1-bit TIFFs that Adobe
    /// applications write as EPS previews (ImageIO can choke on palette+alpha).
    static func decodeSimple(_ t: [UInt8]) -> CGImage? {
        guard t.count > 8 else { return nil }
        let le: Bool
        if t[0] == 0x49 && t[1] == 0x49 { le = true }
        else if t[0] == 0x4D && t[1] == 0x4D { le = false }
        else { return nil }

        func u16(_ o: Int) -> Int {
            guard o >= 0, o + 2 <= t.count else { return 0 }
            return le ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])
        }
        func u32(_ o: Int) -> Int {
            guard o >= 0, o + 4 <= t.count else { return 0 }
            return le
                ? Int(t[o]) | Int(t[o + 1]) << 8 | Int(t[o + 2]) << 16 | Int(t[o + 3]) << 24
                : Int(t[o]) << 24 | Int(t[o + 1]) << 16 | Int(t[o + 2]) << 8 | Int(t[o + 3])
        }

        guard u16(2) == 42 else { return nil }
        let ifd = u32(4)
        guard ifd + 2 <= t.count else { return nil }
        let wanted: Set<Int> = [256, 257, 258, 259, 262, 273, 277, 278, 279, 284, 320, 338]
        var tags: [Int: [Int]] = [:]
        for k in 0..<u16(ifd) {
            let e = ifd + 2 + k * 12
            guard e + 12 <= t.count else { break }
            let tag = u16(e)
            guard wanted.contains(tag) else { continue }
            let type = u16(e + 2), count = u32(e + 4)
            let size: Int
            switch type {
            case 1, 6, 7: size = 1
            case 3, 8: size = 2
            case 4, 9: size = 4
            default: continue
            }
            guard count > 0, count < 5_000_000 else { continue }
            let base = size * count <= 4 ? e + 8 : u32(e + 8)
            guard base + size * count <= t.count else { continue }
            var vals = [Int]()
            vals.reserveCapacity(count)
            for j in 0..<count {
                let o = base + j * size
                vals.append(size == 1 ? Int(t[o]) : (size == 2 ? u16(o) : u32(o)))
            }
            tags[tag] = vals
        }

        guard let w = tags[256]?.first, let h = tags[257]?.first,
              w > 0, h > 0, w * h < 100_000_000 else { return nil }
        let bps = tags[258]?.first ?? 1
        let compression = tags[259]?.first ?? 1
        let photometric = tags[262]?.first ?? 1
        let spp = tags[277]?.first ?? 1
        let planar = tags[284]?.first ?? 1
        guard compression == 1, planar == 1 || spp == 1,
              let offsets = tags[273], let counts = tags[279], offsets.count == counts.count
        else { return nil }

        var raw = [UInt8]()
        for (o, c) in zip(offsets, counts) {
            guard o >= 0, c >= 0, o + c <= t.count else { return nil }
            raw.append(contentsOf: t[o..<(o + c)])
        }

        var out = [UInt8](repeating: 255, count: w * h * 4)

        if bps == 8 {
            let colorChannels: Int
            switch photometric {
            case 0, 1, 3: colorChannels = 1
            case 2: colorChannels = 3
            default: return nil
            }
            guard spp >= colorChannels else { return nil }
            let extra = tags[338] ?? []
            let hasAlpha = spp > colorChannels && !extra.isEmpty && (extra[0] == 1 || extra[0] == 2)
            let premultiplied = hasAlpha && extra[0] == 1 && photometric != 3
            let rowBytes = w * spp
            guard raw.count >= rowBytes * h else { return nil }
            var cmap = [Int]()
            if photometric == 3 {
                guard let cm = tags[320], cm.count >= 768 else { return nil }
                cmap = cm
            }
            for y in 0..<h {
                for x in 0..<w {
                    let p = y * rowBytes + x * spp
                    var r: Int, g: Int, bl: Int
                    switch photometric {
                    case 0:
                        let v = 255 - Int(raw[p]); r = v; g = v; bl = v
                    case 1:
                        let v = Int(raw[p]); r = v; g = v; bl = v
                    case 2:
                        r = Int(raw[p]); g = Int(raw[p + 1]); bl = Int(raw[p + 2])
                    default:
                        let idx = Int(raw[p])
                        r = cmap[idx] >> 8; g = cmap[256 + idx] >> 8; bl = cmap[512 + idx] >> 8
                    }
                    if hasAlpha {
                        let a = Int(raw[p + colorChannels])
                        if premultiplied {
                            r = min(255, r + 255 - a); g = min(255, g + 255 - a); bl = min(255, bl + 255 - a)
                        } else {
                            r = (r * a + 255 * (255 - a)) / 255
                            g = (g * a + 255 * (255 - a)) / 255
                            bl = (bl * a + 255 * (255 - a)) / 255
                        }
                    }
                    let o = (y * w + x) * 4
                    out[o] = UInt8(r); out[o + 1] = UInt8(g); out[o + 2] = UInt8(bl)
                }
            }
        } else if bps == 1 && spp == 1 && (photometric == 0 || photometric == 1) {
            let rowBytes = (w + 7) / 8
            guard raw.count >= rowBytes * h else { return nil }
            for y in 0..<h {
                for x in 0..<w {
                    let bit = (raw[y * rowBytes + x / 8] >> (7 - UInt8(x % 8))) & 1
                    let white = photometric == 0 ? bit == 0 : bit == 1
                    let v: UInt8 = white ? 255 : 0
                    let o = (y * w + x) * 4
                    out[o] = v; out[o + 1] = v; out[o + 2] = v
                }
            }
        } else {
            return nil
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - 3. XMP thumbnail

enum XMPThumbnail {
    static func decode(_ b: [UInt8], ps: Range<Int>) -> CGImage? {
        let open = Array("<xmpGImg:image>".utf8)
        let close = Array("</xmpGImg:image>".utf8)
        guard let s = findBytes(b, open, from: ps.lowerBound, to: ps.upperBound) else { return nil }
        let start = s + open.count
        guard let e = findBytes(b, close, from: start, to: min(ps.upperBound, start + 10_000_000)) else { return nil }
        let text = latin1(b, start..<e)
            .replacingOccurrences(of: "&#xA;", with: "")
            .replacingOccurrences(of: "&#xD;", with: "")
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return nil }
        return EPSDecoder.imageFromData(data)
    }
}
