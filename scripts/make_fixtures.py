#!/usr/bin/env python3
"""Generate small synthetic EPS test files that mimic the structures written by
Adobe Photoshop and Adobe Illustrator. They contain only flat colour blocks
(no real artwork) and are used by the CI decoder test (Tests/main.swift).

Requires: Pillow.   Usage: python3 scripts/make_fixtures.py Tests/Fixtures
"""
import base64
import io
import os
import struct
import sys

from PIL import Image

OUT = sys.argv[1] if len(sys.argv) > 1 else "Tests/Fixtures"
os.makedirs(OUT, exist_ok=True)


# ---------------------------------------------------------------- helpers
def tiff_palette(width, height, pixel, bps_count=2, with_alpha=True):
    """Uncompressed little-endian palette TIFF (like Photoshop/Illustrator EPS
    previews): 8-bit index (+ optional associated alpha). `pixel(x, y)` returns
    (r, g, b, a) with r/g/b already in the palette."""
    palette = []
    idx_of = {}
    data = bytearray()
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixel(x, y)
            if (r, g, b) not in idx_of:
                idx_of[(r, g, b)] = len(palette)
                palette.append((r, g, b))
            data.append(idx_of[(r, g, b)])
            if with_alpha:
                data.append(a)
    spp = 2 if with_alpha else 1
    cmap = [0] * 768
    for i, (r, g, b) in enumerate(palette):
        cmap[i], cmap[256 + i], cmap[512 + i] = r * 257, g * 257, b * 257

    entries = []  # (tag, type, count, payload-bytes)
    def short(tag, *vals):
        entries.append((tag, 3, len(vals), b"".join(struct.pack("<H", v) for v in vals)))
    def long_(tag, *vals):
        entries.append((tag, 4, len(vals), b"".join(struct.pack("<I", v) for v in vals)))

    short(256, width); short(257, height)
    if with_alpha and bps_count == 2:
        short(258, 8, 8)
    else:
        short(258, 8)                       # Illustrator writes a single value
    short(259, 1); short(262, 3)
    long_(273, 0)                           # patched below
    short(277, spp); long_(278, height); long_(279, len(data))
    short(284, 1)
    short(320, *cmap)
    if with_alpha:
        short(338, 1)                       # associated alpha
    entries.sort(key=lambda e: e[0])

    ifd_off = 8
    ifd_size = 2 + 12 * len(entries) + 4
    extra_off = ifd_off + ifd_size
    extra = bytearray()
    placed = []
    for tag, typ, cnt, payload in entries:
        if len(payload) <= 4:
            placed.append((tag, typ, cnt, payload.ljust(4, b"\0"), None))
        else:
            placed.append((tag, typ, cnt, None, extra_off + len(extra)))
            extra += payload
            if len(extra) % 2:
                extra += b"\0"
    strip_off = extra_off + len(extra)
    ifd = bytearray(struct.pack("<H", len(entries)))
    for tag, typ, cnt, inline, off in placed:
        if tag == 273:
            inline = struct.pack("<I", strip_off)
        ifd += struct.pack("<HHI", tag, typ, cnt)
        ifd += inline if inline is not None else struct.pack("<I", off)
    ifd += struct.pack("<I", 0)
    return bytes(b"II*\0" + struct.pack("<I", ifd_off) + ifd + extra + data)


def tiff_bilevel(width, height, black):
    """1-bit WhiteIsZero TIFF (Illustrator 'TIFF (Black & White)' preview)."""
    row = (width + 7) // 8
    data = bytearray(row * height)
    for y in range(height):
        for x in range(width):
            if black(x, y):
                data[y * row + x // 8] |= 0x80 >> (x % 8)
    entries = [
        (256, 3, 1, struct.pack("<HH", width, 0)),
        (257, 3, 1, struct.pack("<HH", height, 0)),
        (258, 3, 1, struct.pack("<HH", 1, 0)),
        (259, 3, 1, struct.pack("<HH", 1, 0)),
        (262, 3, 1, struct.pack("<HH", 0, 0)),   # WhiteIsZero
        (273, 4, 1, None),
        (277, 3, 1, struct.pack("<HH", 1, 0)),
        (278, 4, 1, struct.pack("<I", height)),
        (279, 4, 1, struct.pack("<I", len(data))),
    ]
    strip_off = 8 + 2 + 12 * len(entries) + 4
    ifd = bytearray(struct.pack("<H", len(entries)))
    for tag, typ, cnt, payload in entries:
        if payload is None:
            payload = struct.pack("<I", strip_off)
        ifd += struct.pack("<HHI", tag, typ, cnt) + payload
    ifd += struct.pack("<I", 0)
    return bytes(b"II*\0" + struct.pack("<I", 8) + ifd + data)


def dos_eps(ps, tiff=b""):
    header_len = 30
    ps_off = header_len
    tiff_off = ps_off + len(ps) if tiff else 0
    hdr = b"\xc5\xd0\xd3\xc6" + struct.pack("<6I", ps_off, len(ps), 0, 0, tiff_off, len(tiff)) + b"\xff\xff"
    return hdr + ps + tiff


def cmyk_jpeg_raw(width, height, raw):
    """JPEG whose *stored* CMYK samples equal raw(x, y) (PostScript semantics:
    0 = no ink). Pillow stores 255-value, so we hand it the complement."""
    im = Image.new("CMYK", (width, height))
    im.putdata([tuple(255 - v for v in raw(x, y)) for y in range(height) for x in range(width)])
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=95)
    return buf.getvalue()


def a85(data):
    return base64.a85encode(data, wrapcol=64) + b"~>"


RED_INK = (0, 255, 255, 0)       # C M Y K  (full magenta + yellow = red)
NO_INK = (0, 0, 0, 0)


def photoshop_head(title, w, h, mode, enc, filters, decode):
    return (
        "%!PS-Adobe-3.1 EPSF-3.0\r\n"
        "%ADO_DSC_Encoding: MacOS Roman\r\n"
        "%%Creator: Adobe Photoshop Version 25.7.0\r\n"
        f"%%Title: {title}\r\n"
        f"%%BoundingBox: 0 0 {w} {h}\r\n"
        "%%EndComments\r\n%%BeginProlog\r\n%%EndProlog\r\n%%BeginSetup\r\n%%EndSetup\r\n"
        f'%ImageData: {w} {h} 8 {mode} 0 1 {enc} "beginimage"\r\n'
        "gsave\r\n/rows " + str(h) + " def\r\n/cols " + str(w) + " def\r\n"
        "/beginimage level2 {/image load def} if\r\n"
        "12 dict begin\r\n/ImageType 1 def\r\n/Width cols def\r\n/Height rows def\r\n"
        f"/Decode [{decode}] def\r\n"
        f"/DataSource currentfile {filters} def\r\ncurrentdict end\r\n"
    ).encode("latin-1")


# ------------------------------------------- 1. Photoshop CMYK, ASCII85 + JPEG
W, H = 64, 48
raw = lambda x, y: RED_INK if x < W // 2 else NO_INK
jpg = cmyk_jpeg_raw(W, H, raw)
body = photoshop_head("ps_cmyk_a85_jpeg.eps", W, H, 4, 6,
                      "/ASCII85Decode filter /DCTDecode filter", "0 1 0 1 0 1 0 1")
payload = a85(jpg)
body += b"%%BeginBinary: " + str(len(payload) + 12).encode() + b"\r\nbeginimage\r\n" + payload
body += b"\r\n%%EndBinary\r\ngrestore\r\n%%EOF\r\n"
prev = tiff_palette(W // 4, H // 4, lambda x, y: (255, 0, 0, 255) if x < W // 8 else (255, 255, 255, 255))
open(f"{OUT}/ps_cmyk_a85_jpeg.eps", "wb").write(dos_eps(body, prev))

# ------------------------------------------- 2. Photoshop CMYK, binary JPEG (no DOS header)
body = photoshop_head("ps_cmyk_binary_jpeg.eps", W, H, 4, 6, "/DCTDecode filter", "0 1 0 1 0 1 0 1")
body += b"%%BeginBinary: " + str(len(jpg) + 12).encode() + b"\r\nbeginimage\r\n" + jpg
body += b"\r\n%%EndBinary\r\ngrestore\r\n%%EOF\r\n"
open(f"{OUT}/ps_cmyk_binary_jpeg.eps", "wb").write(body)

# ------------------------------------------- 3. Photoshop RGB, ASCII hex raw
W3, H3 = 16, 8
pix = bytearray()
for y in range(H3):
    for x in range(W3):
        pix += bytes((255, 255, 0)) if x < W3 // 2 else bytes((0, 0, 0))
hexdata = pix.hex().upper().encode()
lines = b"\r\n".join(hexdata[i:i + 64] for i in range(0, len(hexdata), 64))
body = photoshop_head("ps_rgb_hex.eps", W3, H3, 3, 2, "/ASCIIHexDecode filter", "0 1 0 1 0 1")
body += b"%%BeginData: 1 Hex Lines\r\nbeginimage\r\n" + lines + b">\r\n%%EndData\r\ngrestore\r\n%%EOF\r\n"
open(f"{OUT}/ps_rgb_hex.eps", "wb").write(body)

# ------------------------------------------- 4. Illustrator with palette TIFF preview
W4, H4 = 40, 30
ai_ps = (
    "%!PS-Adobe-3.1 EPSF-3.0\r\n%%Title: (Adobe Illustrator Artwork)\r\n"
    "%%Creator: (Adobe Illustrator\\(R\\) 28.7)\r\n"
    f"%%BoundingBox: 0 0 {W4} {H4}\r\n%%EndComments\r\n%%EOF\r\n"
).encode()
prev = tiff_palette(W4, H4, lambda x, y: (0, 0, 255, 255) if y < H4 // 2 else (0, 160, 0, 255), bps_count=1)
open(f"{OUT}/ai_tiff_preview.eps", "wb").write(dos_eps(ai_ps, prev))

# ------------------------------------------- 5. Illustrator with 1-bit preview
prev = tiff_bilevel(W4, H4, lambda x, y: x < W4 // 2)
open(f"{OUT}/ai_bilevel_preview.eps", "wb").write(dos_eps(ai_ps, prev))

# ------------------------------------------- 6. Illustrator, no preview, XMP thumbnail only
buf = io.BytesIO()
Image.new("RGB", (32, 24), (0, 170, 0)).save(buf, "JPEG", quality=95)
b64 = base64.b64encode(buf.getvalue()).decode()
b64 = "&#xA;".join(b64[i:i + 76] for i in range(0, len(b64), 76))
xmp_ps = (
    "%!PS-Adobe-3.1 EPSF-3.0\r\n%%Creator: (Adobe Illustrator\\(R\\) 28.7)\r\n"
    "%%BoundingBox: 0 0 32 24\r\n%%EndComments\r\n"
    "<xmp:Thumbnails><rdf:Alt><rdf:li rdf:parseType=\"Resource\">"
    "<xmpGImg:width>32</xmpGImg:width><xmpGImg:height>24</xmpGImg:height>"
    "<xmpGImg:format>JPEG</xmpGImg:format>"
    f"<xmpGImg:image>{b64}</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>\r\n%%EOF\r\n"
).encode()
open(f"{OUT}/ai_xmp_only.eps", "wb").write(xmp_ps)

# ------------------------------------------- 7. Plain PostScript, nothing to show
open(f"{OUT}/no_preview.eps", "wb").write(b"%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\n0 0 moveto\n%%EOF\n")

print("fixtures written to", OUT)
