// Realistic example pictures for the Coin Purse website: three "photos"
// (parking sign, grocery list, back of a gift card) and two "screenshots"
// (conference badge email, store return code). Everything is made up.
// usage: swift scripts/make-photos.swift <output folder>
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "img"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: cs, .outputColorSpace: cs])
var rng = SystemRandomNumberGenerator()

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &rng) }

/// Canvas with y pointing down, like a page.
func canvas(_ w: CGFloat, _ h: CGFloat, alpha: Bool = false) -> CGContext {
    let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
    ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func font(_ size: CGFloat, bold: Bool = false, name: String? = nil) -> CTFont {
    if let name { return CTFontCreateWithName(name as CFString, size, nil) }
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    if bold, let f = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) { return f }
    return base
}

@discardableResult
func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, _ f: CTFont, _ color: CGColor, align: Int = 0, kern: CGFloat = 0) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let dx = align == 1 ? -w / 2 : align == 2 ? -w : 0
    ctx.saveGState()
    ctx.translateBy(x: x + dx, y: y + CTFontGetAscent(f))
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    return w
}

/// Wraps a paragraph into lines that fit `width`; returns the y after the last line.
@discardableResult
func paragraph(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ f: CTFont, _ color: CGColor, lineHeight: CGFloat) -> CGFloat {
    var line = "", yy = y
    let measure: (String) -> CGFloat = { str in
        let a: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f]
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: a)), nil, nil, nil))
    }
    for word in s.split(separator: " ") {
        let trial = line.isEmpty ? String(word) : line + " " + word
        if measure(trial) > width, !line.isEmpty {
            text(ctx, line, x, yy, f, color); yy += lineHeight; line = String(word)
        } else { line = trial }
    }
    if !line.isEmpty { text(ctx, line, x, yy, f, color); yy += lineHeight }
    return yy
}

func code(_ filter: String, _ payload: String, scale: CGFloat) -> CGImage {
    let f = CIFilter(name: filter)!
    f.setValue(payload.data(using: .ascii), forKey: "inputMessage")
    if filter == "CIQRCodeGenerator" { f.setValue("M", forKey: "inputCorrectionLevel") }
    if filter == "CICode128BarcodeGenerator" { f.setValue(0, forKey: "inputQuietSpace") }
    let img = f.outputImage!.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return ci.createCGImage(img, from: img.extent)!
}

/// Draws a CGImage into a y-down canvas without flipping it.
func draw(_ ctx: CGContext, _ img: CGImage, _ r: CGRect, crisp: Bool = true) {
    ctx.saveGState()
    if crisp { ctx.interpolationQuality = .none }
    ctx.translateBy(x: 0, y: r.minY * 2 + r.height); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: r)
    ctx.restoreGState()
}

/// Puts an object image onto a background with perspective (corners TL, TR, BR, BL, y down) and a soft shadow.
func place(_ object: CGImage, on bg: CIImage, corners: [CGPoint], shadow: CGFloat = 0.45, shadowOffset: CGSize = CGSize(width: 14, height: 22)) -> CIImage {
    let H = bg.extent.height
    let up = corners.map { CGPoint(x: $0.x, y: H - $0.y) }
    let obj = CIImage(cgImage: object).applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": CIVector(cgPoint: up[0]), "inputTopRight": CIVector(cgPoint: up[1]),
        "inputBottomRight": CIVector(cgPoint: up[2]), "inputBottomLeft": CIVector(cgPoint: up[3]),
    ])
    let shade = obj.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: shadow),
    ]).transformed(by: CGAffineTransform(translationX: shadowOffset.width, y: -shadowOffset.height))
        .applyingGaussianBlur(sigma: 16)
    return obj.composited(over: shade.composited(over: bg)).cropped(to: bg.extent)
}

/// Camera look: soft focus, grain, warm light falloff, vignette.
func photograph(_ img: CIImage, warmth: CGFloat = 5600, light: CGPoint) -> CIImage {
    let e = img.extent
    var out = img.applyingGaussianBlur(sigma: 0.9).cropped(to: e)
    // Uneven lighting: a bright spot fading out.
    let glow = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": CIVector(x: light.x, y: e.height - light.y), "inputRadius0": 40, "inputRadius1": max(e.width, e.height) * 0.9,
        "inputColor0": CIColor(red: 1, green: 0.98, blue: 0.92, alpha: 0.22), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.28),
    ])!.outputImage!.cropped(to: e)
    out = glow.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: out])
    // Sensor grain.
    let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: e).applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.09),
    ])
    out = grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: out])
    out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: warmth, y: 0)])
    out = out.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.7, kCIInputRadiusKey: 1.4])
    return out.cropped(to: e)
}

func saveJPEG(_ img: CIImage, _ name: String) {
    let cg = ci.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: cs)!
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

func saveContext(_ ctx: CGContext, _ name: String) { saveJPEG(CIImage(cgImage: ctx.makeImage()!), name) }

// Speckle texture for concrete, paper and fabric.
func speckle(_ ctx: CGContext, _ r: CGRect, count: Int, dark: CGColor, light: CGColor, size: ClosedRange<CGFloat>) {
    for _ in 0..<count {
        let s = rnd(size.lowerBound, size.upperBound)
        ctx.setFillColor(Bool.random(using: &rng) ? dark : light)
        ctx.fillEllipse(in: CGRect(x: rnd(r.minX, r.maxX), y: rnd(r.minY, r.maxY), width: s, height: s))
    }
}

// MARK: - Parking garage sign "2C" (photo)

func parkingSign() {
    let W: CGFloat = 1000, H: CGFloat = 1250
    let bg = canvas(W, H)
    // Garage: ceiling, back wall, floor.
    let wall = CGGradient(colorsSpace: cs, colors: [c(0x5A5F66), c(0x8C9096), c(0x6B6F75)] as CFArray, locations: [0, 0.45, 1])!
    bg.drawLinearGradient(wall, start: .zero, end: CGPoint(x: 0, y: H), options: [])
    bg.setFillColor(c(0x3E4247)); bg.fill(CGRect(x: 0, y: 0, width: W, height: 150))
    // Fluorescent light strip with glow.
    bg.saveGState(); bg.setShadow(offset: .zero, blur: 60, color: c(0xFFFDF2, 0.9))
    bg.setFillColor(c(0xFFFEF5)); bg.fill(CGRect(x: 160, y: 96, width: 680, height: 18)); bg.restoreGState()
    // Floor with a painted stall line.
    bg.setFillColor(c(0x44474B)); bg.fill(CGRect(x: 0, y: 1060, width: W, height: 190))
    bg.setFillColor(c(0xE8C547, 0.85))
    bg.beginPath(); bg.move(to: CGPoint(x: 80, y: H)); bg.addLine(to: CGPoint(x: 230, y: 1060)); bg.addLine(to: CGPoint(x: 252, y: 1060)); bg.addLine(to: CGPoint(x: 120, y: H)); bg.fillPath()
    // Concrete pillar.
    let pillar = CGRect(x: 230, y: 150, width: 540, height: 910)
    let pg = CGGradient(colorsSpace: cs, colors: [c(0xA9ACB0), c(0xC9CBCE), c(0x9A9DA1)] as CFArray, locations: [0, 0.5, 1])!
    bg.saveGState(); bg.clip(to: pillar)
    bg.drawLinearGradient(pg, start: CGPoint(x: pillar.minX, y: 0), end: CGPoint(x: pillar.maxX, y: 0), options: [])
    speckle(bg, pillar, count: 9000, dark: c(0x6F7276, 0.35), light: c(0xFFFFFF, 0.25), size: 1...3.5)
    bg.setFillColor(c(0x2563EB)); bg.fill(CGRect(x: pillar.minX, y: 900, width: pillar.width, height: 70))   // painted band
    bg.restoreGState()
    speckle(bg, CGRect(x: 0, y: 150, width: W, height: 910), count: 6000, dark: c(0x3A3D41, 0.25), light: c(0xFFFFFF, 0.12), size: 1...3)

    // The sign itself, drawn flat, then placed in perspective on the pillar.
    let sw: CGFloat = 520, sh: CGFloat = 600
    let sign = canvas(sw, sh, alpha: true)
    sign.setFillColor(c(0x1D4ED8))
    sign.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: sw, height: sh), cornerWidth: 26, cornerHeight: 26, transform: nil)); sign.fillPath()
    sign.setStrokeColor(c(0xFFFFFF)); sign.setLineWidth(10)
    sign.addPath(CGPath(roundedRect: CGRect(x: 18, y: 18, width: sw - 36, height: sh - 36), cornerWidth: 16, cornerHeight: 16, transform: nil)); sign.strokePath()
    text(sign, "LEVEL", sw / 2, 52, font(52, bold: true), c(0xFFFFFF), align: 1, kern: 8)
    text(sign, "2C", sw / 2, 112, font(300, bold: true), c(0xFFFFFF), align: 1, kern: -6)
    sign.setFillColor(c(0xFACC15)); sign.fill(CGRect(x: 40, y: 452, width: sw - 80, height: 104))
    text(sign, "REMEMBER YOUR LEVEL", sw / 2, 486, font(31, bold: true), c(0x111111), align: 1, kern: 1)
    // A little dirt and wear.
    speckle(sign, CGRect(x: 0, y: 0, width: sw, height: sh), count: 700, dark: c(0x000000, 0.12), light: c(0xFFFFFF, 0.08), size: 1...3)

    var img = CIImage(cgImage: bg.makeImage()!)
    // Looking slightly up and from the left.
    img = place(sign.makeImage()!, on: img, corners: [CGPoint(x: 252, y: 300), CGPoint(x: 742, y: 318), CGPoint(x: 736, y: 868), CGPoint(x: 246, y: 880)], shadow: 0.35, shadowOffset: CGSize(width: 8, height: 10))
    saveJPEG(photograph(img, warmth: 5000, light: CGPoint(x: 500, y: 140)), "parking-2c.jpg")
}

// MARK: - Handwritten grocery list (photo)

func groceryList() {
    let W: CGFloat = 1000, H: CGFloat = 1250
    let bg = canvas(W, H)
    // Butcher-block counter.
    bg.setFillColor(c(0x9C6B3E)); bg.fill(CGRect(x: 0, y: 0, width: W, height: H))
    var x: CGFloat = 0
    while x < W {
        let w = rnd(70, 140)
        bg.setFillColor(c([0xA87445, 0x8E5E34, 0xB07D4C, 0x966339].randomElement(using: &rng)!))
        bg.fill(CGRect(x: x, y: 0, width: w, height: H)); x += w
        bg.setFillColor(c(0x5C3A1E, 0.35)); bg.fill(CGRect(x: x - 1.5, y: 0, width: 3, height: H))
    }
    bg.setLineWidth(1.4)
    for _ in 0..<420 {   // grain
        bg.setStrokeColor(Bool.random(using: &rng) ? c(0x5C3A1E, 0.18) : c(0xD9A877, 0.14))
        let gx = rnd(0, W); var gy: CGFloat = rnd(-100, H)
        bg.move(to: CGPoint(x: gx, y: gy))
        for _ in 0..<8 { gy += rnd(20, 60); bg.addLine(to: CGPoint(x: gx + rnd(-4, 4), y: gy)) }
        bg.strokePath()
    }

    // Notepad page.
    let pw: CGFloat = 620, ph: CGFloat = 860
    let page = canvas(pw, ph, alpha: true)
    page.setFillColor(c(0xFDFAF0)); page.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
    speckle(page, CGRect(x: 0, y: 0, width: pw, height: ph), count: 2500, dark: c(0xC8C0A8, 0.25), light: c(0xFFFFFF, 0.4), size: 0.6...2)
    page.setFillColor(c(0x93C5FD, 0.7))
    var ly: CGFloat = 150
    while ly < ph - 20 { page.fill(CGRect(x: 0, y: ly, width: pw, height: 2)); ly += 58 }
    page.setFillColor(c(0xF87171, 0.7)); page.fill(CGRect(x: 78, y: 0, width: 2.5, height: ph))
    // Torn top edge from the pad.
    page.setBlendMode(.clear)
    page.beginPath(); page.move(to: .zero)
    var tx: CGFloat = 0
    while tx < pw { page.addLine(to: CGPoint(x: tx, y: rnd(2, 12))); tx += rnd(6, 14) }
    page.addLine(to: CGPoint(x: pw, y: 0)); page.closePath(); page.fillPath()
    page.setBlendMode(.normal)

    let pen = font(56, name: "BradleyHandITCTT-Bold")
    let ink = c(0x1E3A8A, 0.92)
    func hand(_ s: String, _ y: CGFloat, struck: Bool = false, tick: Bool = false) {
        page.saveGState()
        let px: CGFloat = 104 + rnd(-6, 10)
        page.translateBy(x: px, y: y); page.rotate(by: rnd(-0.03, 0.02))
        let w = text(page, s, 0, 0, pen, ink)
        if struck {
            page.setStrokeColor(ink); page.setLineWidth(4); page.setLineCap(.round)
            page.move(to: CGPoint(x: -6, y: 34)); page.addLine(to: CGPoint(x: w + 8, y: 28 + rnd(-3, 3))); page.strokePath()
        }
        if tick {
            page.setStrokeColor(c(0x15803D, 0.9)); page.setLineWidth(5); page.setLineCap(.round)
            page.move(to: CGPoint(x: w + 22, y: 30)); page.addLine(to: CGPoint(x: w + 34, y: 44)); page.addLine(to: CGPoint(x: w + 60, y: 10)); page.strokePath()
        }
        page.restoreGState()
    }
    text(page, "Groceries", 104, 50, font(70, name: "BradleyHandITCTT-Bold"), ink)
    page.setStrokeColor(ink); page.setLineWidth(3.5); page.move(to: CGPoint(x: 104, y: 128)); page.addLine(to: CGPoint(x: 380, y: 122)); page.strokePath()
    let items: [(String, Bool, Bool)] = [
        ("eggs (dozen)", true, false), ("milk", true, false), ("coffee beans", false, false), ("lemons x4", false, true),
        ("sourdough bread", false, false), ("spinach", false, false), ("chicken thighs", false, false),
        ("paper towels", false, false), ("birthday card!", false, false),
    ]
    for (i, item) in items.enumerated() { hand(item.0, 160 + CGFloat(i) * 58 + 4, struck: item.1, tick: item.2) }

    var img = CIImage(cgImage: bg.makeImage()!)
    img = place(page.makeImage()!, on: img, corners: [CGPoint(x: 205, y: 150), CGPoint(x: 830, y: 205), CGPoint(x: 790, y: 1100), CGPoint(x: 150, y: 1060)], shadow: 0.5)
    saveJPEG(photograph(img, warmth: 4700, light: CGPoint(x: 700, y: 120)), "grocery-list.jpg")
}

// MARK: - Back of a gift card with a barcode (photo)

func giftCard() {
    let W: CGFloat = 1000, H: CGFloat = 1250
    let bg = canvas(W, H)
    bg.setFillColor(c(0x2B2E33)); bg.fill(CGRect(x: 0, y: 0, width: W, height: H))
    speckle(bg, CGRect(x: 0, y: 0, width: W, height: H), count: 26000, dark: c(0x16181B, 0.5), light: c(0x4A4E55, 0.4), size: 1...3)

    let cw: CGFloat = 860, ch: CGFloat = 542
    let card = canvas(cw, ch, alpha: true)
    card.setFillColor(c(0xF8F8F6))
    card.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: cw, height: ch), cornerWidth: 34, cornerHeight: 34, transform: nil)); card.fillPath()
    // Brand corner.
    card.setFillColor(c(0xEA580C)); card.fillEllipse(in: CGRect(x: 40, y: 40, width: 74, height: 74))
    text(card, "☀︎", 77, 50, font(44, bold: true), c(0xFFFFFF), align: 1)
    text(card, "Sunrise Coffee Co.", 132, 46, font(30, bold: true), c(0x111111))
    text(card, "GIFT CARD", 132, 86, font(20, bold: true), c(0xEA580C), kern: 4)
    let bars = code("CICode128BarcodeGenerator", "6048213509", scale: 3.4)
    draw(card, bars, CGRect(x: 40, y: 150, width: cw - 80, height: 110))
    text(card, "6048  2135  0912  7741", cw / 2, 270, font(40, bold: true), c(0x111111), align: 1, kern: 2)
    text(card, "PIN  8302", cw / 2, 322, font(26, bold: true), c(0x6B7280), align: 1, kern: 3)
    paragraph(card, "Scan this barcode at checkout to pay. Check your balance at sunrise-coffee.example. Not redeemable for cash except where required by law.",
              40, 380, cw - 80, font(19), c(0x4B5563), lineHeight: 26)
    card.setFillColor(c(0xEA580C)); card.fill(CGRect(x: 0, y: 492, width: cw, height: 50))
    // Glare from an overhead light.
    let glare = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0), c(0xFFFFFF, 0.35), c(0xFFFFFF, 0)] as CFArray, locations: [0, 0.5, 1])!
    card.saveGState()
    card.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: cw, height: ch), cornerWidth: 34, cornerHeight: 34, transform: nil)); card.clip()
    card.drawLinearGradient(glare, start: CGPoint(x: 120, y: 0), end: CGPoint(x: 420, y: ch), options: [])
    card.restoreGState()

    var img = CIImage(cgImage: bg.makeImage()!)
    img = place(card.makeImage()!, on: img, corners: [CGPoint(x: 92, y: 370), CGPoint(x: 922, y: 330), CGPoint(x: 950, y: 868), CGPoint(x: 70, y: 905)], shadow: 0.6)
    saveJPEG(photograph(img, warmth: 5300, light: CGPoint(x: 360, y: 280)), "gift-card.jpg")
}

// MARK: - Screenshots

func statusBar(_ ctx: CGContext, _ W: CGFloat, dark: Bool = false) {
    let ink = dark ? c(0xFFFFFF) : c(0x111111)
    text(ctx, "9:41", 44, 26, font(30, bold: true), ink)
    ctx.setFillColor(ink)
    for (i, h) in [10.0, 15.0, 20.0, 25.0].enumerated() { ctx.fill(CGRect(x: W - 160 + CGFloat(i) * 10, y: 52 - h, width: 7, height: h)) }
    ctx.setStrokeColor(dark ? c(0xFFFFFF, 0.5) : c(0x111111, 0.5)); ctx.setLineWidth(2.5)
    ctx.addPath(CGPath(roundedRect: CGRect(x: W - 100, y: 30, width: 54, height: 25), cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.strokePath()
    ctx.fill(CGRect(x: W - 95, y: 35, width: 38, height: 15))
}

func conferenceBadge() {
    let W: CGFloat = 640, H: CGFloat = 1300
    let ctx = canvas(W, H)
    ctx.setFillColor(c(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    statusBar(ctx, W)
    text(ctx, "‹ Inbox", 30, 92, font(30), c(0x2563EB))
    text(ctx, "Your DevSummit 2026 badge", 34, 160, font(38, bold: true), c(0x111111))
    ctx.setFillColor(c(0x7C3AED)); ctx.fillEllipse(in: CGRect(x: 34, y: 230, width: 64, height: 64))
    text(ctx, "DS", 66, 245, font(26, bold: true), c(0xFFFFFF), align: 1)
    text(ctx, "DevSummit Registration", 116, 232, font(28, bold: true), c(0x111111))
    text(ctx, "To: you   ·   Sep 30", 116, 270, font(24), c(0x6B7280))
    ctx.setFillColor(c(0xE5E7EB)); ctx.fill(CGRect(x: 34, y: 322, width: W - 68, height: 2))
    paragraph(ctx, "Hi Alex, you are all set! Show this code at any check-in desk to print your badge.", 34, 348, W - 68, font(28), c(0x374151), lineHeight: 40)
    // Badge card.
    let card = CGRect(x: 60, y: 470, width: W - 120, height: 690)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 24, color: c(0x000000, 0.15))
    ctx.setFillColor(c(0xFFFFFF)); ctx.addPath(CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.fillPath(); ctx.restoreGState()
    let head = CGRect(x: card.minX, y: card.minY, width: card.width, height: 120)
    ctx.saveGState(); ctx.addPath(CGPath(roundedRect: CGRect(x: head.minX, y: head.minY, width: head.width, height: head.height + 30), cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.clip(); ctx.clip(to: head)
    let g = CGGradient(colorsSpace: cs, colors: [c(0x7C3AED), c(0x2563EB)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: head.minX, y: 0), end: CGPoint(x: head.maxX, y: 0), options: []); ctx.restoreGState()
    text(ctx, "DEVSUMMIT 2026", head.midX, head.minY + 26, font(36, bold: true), c(0xFFFFFF), align: 1, kern: 4)
    text(ctx, "Oct 14 to 16 · Downtown Convention Center", head.midX, head.minY + 76, font(21), c(0xFFFFFF, 0.9), align: 1)
    let q = code("CIQRCodeGenerator", "https://example.com/devsummit/badge/DS-7731", scale: 11)
    draw(ctx, q, CGRect(x: card.midX - 160, y: head.maxY + 40, width: 320, height: 320))
    text(ctx, "Alex Rivera", card.midX, head.maxY + 386, font(40, bold: true), c(0x111111), align: 1)
    text(ctx, "Full Conference Pass", card.midX, head.maxY + 440, font(28), c(0x6B7280), align: 1)
    text(ctx, "Registration DS-7731", card.midX, head.maxY + 490, font(24, bold: true), c(0x7C3AED), align: 1)
    saveContext(ctx, "conference-badge.jpg")
}

func returnCode() {
    let W: CGFloat = 640, H: CGFloat = 1300
    let ctx = canvas(W, H)
    ctx.setFillColor(c(0xF5F5F4)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    statusBar(ctx, W)
    text(ctx, "‹ Orders", 30, 92, font(30), c(0xEA580C))
    text(ctx, "Return started", 34, 160, font(44, bold: true), c(0x111111))
    text(ctx, "Order RC-20931 · 1 item", 34, 220, font(26), c(0x6B7280))
    let card = CGRect(x: 34, y: 282, width: W - 68, height: 760)
    ctx.setFillColor(c(0xFFFFFF)); ctx.addPath(CGPath(roundedRect: card, cornerWidth: 24, cornerHeight: 24, transform: nil)); ctx.fillPath()
    text(ctx, "Your return code", card.midX, card.minY + 36, font(32, bold: true), c(0x111111), align: 1)
    let q = code("CIQRCodeGenerator", "https://example.com/returns/RC-20931", scale: 11)
    draw(ctx, q, CGRect(x: card.midX - 170, y: card.minY + 96, width: 340, height: 340))
    paragraph(ctx, "Show this code at any ShipPoint drop-off. No box or label needed.", card.minX + 40, card.minY + 470, card.width - 80, font(27), c(0x374151), lineHeight: 38)
    ctx.setFillColor(c(0xFFEDD5)); ctx.addPath(CGPath(roundedRect: CGRect(x: card.minX + 40, y: card.minY + 572, width: card.width - 80, height: 70), cornerWidth: 16, cornerHeight: 16, transform: nil)); ctx.fillPath()
    text(ctx, "Return by Fri, Oct 24, 2026", card.midX, card.minY + 591, font(28, bold: true), c(0x9A3412), align: 1)
    text(ctx, "Refund to original payment", card.midX, card.minY + 680, font(24), c(0x6B7280), align: 1)
    // Item row.
    let item = CGRect(x: 34, y: card.maxY + 26, width: W - 68, height: 150)
    ctx.setFillColor(c(0xFFFFFF)); ctx.addPath(CGPath(roundedRect: item, cornerWidth: 24, cornerHeight: 24, transform: nil)); ctx.fillPath()
    ctx.setFillColor(c(0xE7E5E4)); ctx.addPath(CGPath(roundedRect: CGRect(x: item.minX + 24, y: item.minY + 25, width: 100, height: 100), cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
    text(ctx, "Trail running shoes", item.minX + 148, item.minY + 40, font(28, bold: true), c(0x111111))
    text(ctx, "Size 10 · Slate blue", item.minX + 148, item.minY + 82, font(24), c(0x6B7280))
    saveContext(ctx, "return-label.jpg")
}

parkingSign()
groceryList()
giftCard()
conferenceBadge()
returnCode()
print("done")
