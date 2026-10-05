// Two made-up tailgate e-ticket "screenshots" for the website demo.
// usage: swift scripts/make-tickets.swift t1.png t2.png, then convert to img/ticket-1.jpg and img/ticket-2.jpg
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let W: CGFloat = 640, H: CGFloat = 1300
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func font(_ size: CGFloat, bold: Bool = false, heavy: Bool = false) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    if heavy, let f = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) { return f }
    if bold, let f = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) { return f }
    return base
}

/// Draws text with its top-left at (x, y) in a y-down canvas. align: 0 left, 1 center, 2 right.
func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, _ f: CTFont, _ color: CGColor, align: Int = 0, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    let dx = align == 1 ? -CGFloat(w) / 2 : align == 2 ? -CGFloat(w) : 0
    ctx.saveGState()
    ctx.translateBy(x: x + dx, y: y + CTFontGetAscent(f))
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func qr(_ payload: String) -> CGImage {
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(payload.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    let img = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    return CIContext().createCGImage(img, from: img.extent)!
}

func ticket(number: Int, of total: Int, order: String, space: String, out: String) {
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // y down

    // Phone screenshot: light app background and a status bar.
    ctx.setFillColor(c(0xF2F2F7)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    text(ctx, "9:41", 44, 26, font(30, bold: true), c(0x111111))
    ctx.setFillColor(c(0x111111))
    for (i, h) in [10.0, 15.0, 20.0, 25.0].enumerated() { ctx.fill(CGRect(x: 480 + CGFloat(i) * 10, y: 52 - h, width: 7, height: h)) }
    let battery = CGRect(x: 540, y: 30, width: 54, height: 25)
    ctx.setStrokeColor(c(0x111111, 0.5)); ctx.setLineWidth(2.5)
    ctx.addPath(CGPath(roundedRect: battery, cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.strokePath()
    ctx.fill(CGRect(x: 545, y: 35, width: 38, height: 15))

    // App header.
    text(ctx, "‹  My Tickets", 34, 96, font(30), c(0x2563EB))
    text(ctx, "Ticket \(number) of \(total)", W - 34, 96, font(28, bold: true), c(0x6B7280), align: 2)

    // Ticket card.
    let card = CGRect(x: 34, y: 160, width: W - 68, height: 1080)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: c(0x000000, 0.18))
    ctx.setFillColor(c(0xFFFFFF))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 34, cornerHeight: 34, transform: nil)); ctx.fillPath()
    ctx.restoreGState()

    // Event banner: sunset gradient, stripes, title.
    let banner = CGRect(x: card.minX, y: card.minY, width: card.width, height: 330)
    ctx.saveGState()
    let clip = CGMutablePath()
    clip.addRoundedRect(in: CGRect(x: banner.minX, y: banner.minY, width: banner.width, height: banner.height + 40), cornerWidth: 34, cornerHeight: 34)
    ctx.addPath(clip); ctx.clip()
    ctx.clip(to: banner)
    let g = CGGradient(colorsSpace: cs, colors: [c(0x16A34A), c(0x0E7490), c(0x1E3A8A)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: banner.minX, y: banner.minY), end: CGPoint(x: banner.maxX, y: banner.maxY), options: [])
    ctx.setStrokeColor(c(0xFFFFFF, 0.08)); ctx.setLineWidth(26)
    for i in stride(from: -400.0, to: 900.0, by: 70.0) {
        ctx.move(to: CGPoint(x: banner.minX + i, y: banner.maxY)); ctx.addLine(to: CGPoint(x: banner.minX + i + 330, y: banner.minY))
    }
    ctx.strokePath()
    // Football laces motif.
    ctx.setFillColor(c(0xFFFFFF, 0.14))
    ctx.fillEllipse(in: CGRect(x: banner.maxX - 210, y: banner.minY + 40, width: 230, height: 140))
    ctx.restoreGState()
    text(ctx, "HOMECOMING", banner.minX + 36, banner.minY + 44, font(30, bold: true), c(0xFFFFFF, 0.85), kern: 5)
    text(ctx, "TAILGATE PASS", banner.minX + 36, banner.minY + 84, font(58, heavy: true), c(0xFFFFFF), kern: 1)
    text(ctx, "Rocky Ridge Rams vs. Summit Hawks", banner.minX + 36, banner.minY + 168, font(30, bold: true), c(0xFFFFFF))
    text(ctx, "SAT · OCT 18 · 2026", banner.minX + 36, banner.minY + 220, font(28, bold: true), c(0xFDE68A), kern: 2)
    text(ctx, "Lot opens 9:00 AM · Kickoff 1:30 PM", banner.minX + 36, banner.minY + 262, font(26), c(0xFFFFFF, 0.9))

    // Details grid.
    let rows: [(String, String, String, String)] = [
        ("LOT", "C · North Fields", "SPACE", space),
        ("ADMIT", "1 Guest", "TICKET", "\(number) of \(total)"),
    ]
    var y = banner.maxY + 34
    for (k1, v1, k2, v2) in rows {
        text(ctx, k1, card.minX + 36, y, font(22, bold: true), c(0x9CA3AF), kern: 2)
        text(ctx, v1, card.minX + 36, y + 30, font(32, bold: true), c(0x111827))
        text(ctx, k2, card.minX + 360, y, font(22, bold: true), c(0x9CA3AF), kern: 2)
        text(ctx, v2, card.minX + 360, y + 30, font(32, bold: true), c(0x111827))
        y += 96
    }

    // Perforation with side notches.
    let py = y + 6
    ctx.setFillColor(c(0xF2F2F7))
    ctx.fillEllipse(in: CGRect(x: card.minX - 22, y: py - 22, width: 44, height: 44))
    ctx.fillEllipse(in: CGRect(x: card.maxX - 22, y: py - 22, width: 44, height: 44))
    ctx.setStrokeColor(c(0xD1D5DB)); ctx.setLineWidth(3); ctx.setLineDash(phase: 0, lengths: [12, 10])
    ctx.move(to: CGPoint(x: card.minX + 34, y: py)); ctx.addLine(to: CGPoint(x: card.maxX - 34, y: py)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // QR code (a real, harmless example link).
    let code = qr("https://example.com/tailgate/\(order)/\(number)")
    let side: CGFloat = 330
    let qrRect = CGRect(x: (W - side) / 2, y: py + 46, width: side, height: side)
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.translateBy(x: 0, y: qrRect.minY * 2 + side); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(code, in: qrRect)
    ctx.restoreGState()
    text(ctx, "Scan at the lot entrance", W / 2, qrRect.maxY + 26, font(26, bold: true), c(0x111827), align: 1)
    text(ctx, "Order \(order) · Ticket \(number)", W / 2, qrRect.maxY + 66, font(24), c(0x6B7280), align: 1)

    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

ticket(number: 1, of: 2, order: "TG-48213", space: "14", out: CommandLine.arguments[1])
ticket(number: 2, of: 2, order: "TG-48213", space: "14", out: CommandLine.arguments[2])
