// Decoder test tool, run on the CI Mac before building the app:
//   swiftc -O -o build/decoder-test Sources/Shared/EPSDecoder.swift Tests/main.swift
//   build/decoder-test Tests/Fixtures
import Foundation
import CoreGraphics

struct Expect {
    let file: String
    let method: String?          // nil = decoding must fail
    let width: Int
    let height: Int
    /// (x, y) sample → (r, g, b) roughly expected
    let samples: [((Int, Int), (Int, Int, Int))]
}

let red = (230, 30, 40), white = (255, 255, 255), yellow = (255, 255, 0), black = (0, 0, 0)
let blue = (0, 0, 255), green = (0, 160, 0), green2 = (0, 170, 0)

let cases: [Expect] = [
    Expect(file: "ps_cmyk_a85_jpeg.eps", method: "photoshop-jpeg", width: 64, height: 48,
           samples: [((8, 24), red), ((56, 24), white)]),
    Expect(file: "ps_cmyk_binary_jpeg.eps", method: "photoshop-jpeg", width: 64, height: 48,
           samples: [((8, 24), red), ((56, 24), white)]),
    Expect(file: "ps_rgb_hex.eps", method: "photoshop-raw", width: 16, height: 8,
           samples: [((2, 4), yellow), ((13, 4), black)]),
    Expect(file: "ai_tiff_preview.eps", method: "tiff-preview", width: 40, height: 30,
           samples: [((20, 5), blue), ((20, 25), green)]),
    // 40x40 blue box inside a 100x80 artboard with a frame line: trimmed to box + 4 px padding.
    Expect(file: "ai_margin_preview.eps", method: "tiff-preview", width: 48, height: 48,
           samples: [((24, 24), blue), ((1, 1), white)]),
    // Left half black: white right half is trimmed down to 4 px padding.
    Expect(file: "ai_bilevel_preview.eps", method: "tiff-preview", width: 24, height: 30,
           samples: [((5, 15), black), ((22, 15), white)]),
    Expect(file: "ai_xmp_only.eps", method: "xmp-thumbnail", width: 32, height: 24,
           samples: [((16, 12), green2)]),
    Expect(file: "no_preview.eps", method: nil, width: 0, height: 0, samples: []),
]

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures"
print("ImageIO inverts EPS-style CMYK JPEG: \(EPSDecoder.imageIOInvertsEPSCMYK)")

var failures = 0
func fail(_ msg: String) { print("  ✗ " + msg); failures += 1 }

for c in cases {
    print("• \(c.file)")
    let url = URL(fileURLWithPath: dir).appendingPathComponent(c.file)
    do {
        let r = try EPSDecoder.decode(url: url)
        guard let method = c.method else { fail("expected failure, got \(r.method)"); continue }
        if r.method != method { fail("method \(r.method) != \(method)") }
        if r.image.width != c.width || r.image.height != c.height {
            fail("size \(r.image.width)x\(r.image.height) != \(c.width)x\(c.height)")
        }
        for ((x, y), (er, eg, eb)) in c.samples {
            guard let p = EPSDecoder.samplePixel(r.image, x: x, y: y) else { fail("sample failed"); continue }
            let d = max(abs(p.r - er), abs(p.g - eg), abs(p.b - eb))
            let ok = d <= 70
            print("  pixel(\(x),\(y)) = (\(p.r),\(p.g),\(p.b)) expected ≈ (\(er),\(eg),\(eb)) \(ok ? "✓" : "")")
            if !ok { fail("colour mismatch at (\(x),\(y))") }
        }
        if let data = EPSDecoder.encode(r.image, jpeg: r.isPhoto) {
            print("  encoded \(data.count) bytes as \(r.isPhoto ? "JPEG" : "PNG")")
        } else {
            fail("encode failed")
        }
    } catch {
        if c.method == nil { print("  ✓ failed as expected: \(error.localizedDescription)") }
        else { fail("decode threw \(error)") }
    }
}

// Optional: time the decoder on any extra files passed after the fixture dir.
for path in CommandLine.arguments.dropFirst(2) {
    let t0 = Date()
    do {
        let r = try EPSDecoder.decode(url: URL(fileURLWithPath: path))
        print("• \(path): \(r.method) \(r.image.width)x\(r.image.height) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    } catch {
        print("• \(path): \(error)")
    }
}

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
