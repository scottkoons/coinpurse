import CoreGraphics
import CoreText
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Coin Purse icon: a silver coin stamped with a cent sign (small change, not the wallet).
// usage: swift scripts/make-icon.swift <out.png> <size> <background:1|0>
//   App icon: ios/CoinPurse/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png 1024 1
//   Logo:     ios/CoinPurse/Assets.xcassets/Logo.imageset/Logo.png 480 0
//   Web:      icons/icon-180.png 180 1 (also 192 and 512)
let out = CommandLine.arguments[1]
let S = CGFloat(Double(CommandLine.arguments[2])!)
let withBackground = CommandLine.arguments[3] == "1"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: (withBackground ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
// 1024 grid, y down.
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: S / 1024, y: -S / 1024)

if withBackground {
    let bg = CGGradient(colorsSpace: cs, colors: [c(0x23202E), c(0x0D0C12)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])
}

let center = CGPoint(x: 512, y: 512)
let R: CGFloat = withBackground ? 330 : 470
func circle(_ r: CGFloat, dy: CGFloat = 0) -> CGRect { CGRect(x: center.x - r, y: center.y - r + dy, width: 2 * r, height: 2 * r) }
func radial(_ colors: [CGColor], _ r: CGFloat, focus: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: focus, startRadius: 0, endCenter: center, endRadius: r, options: [.drawsAfterEndLocation])
}

// Shadow and edge thickness.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: R * 0.07), blur: R * 0.16, color: c(0x000000, withBackground ? 0.6 : 0.35))
ctx.setFillColor(c(0x5E646D))
ctx.fillEllipse(in: circle(R, dy: R * 0.05))
ctx.restoreGState()

// Rim.
ctx.saveGState()
ctx.addEllipse(in: circle(R)); ctx.clip()
radial([c(0xFFFFFF), c(0xD5DAE1), c(0x8C939D)], R, focus: CGPoint(x: center.x - R * 0.35, y: center.y - R * 0.4))
ctx.restoreGState()

// Reeded edge.
ctx.saveGState()
ctx.setStrokeColor(c(0x6E747D, 0.5)); ctx.setLineWidth(R * 0.012)
for i in 0..<120 {
    let a = CGFloat(i) / 120 * 2 * .pi
    ctx.move(to: CGPoint(x: center.x + cos(a) * R * 0.90, y: center.y + sin(a) * R * 0.90))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * R * 0.97, y: center.y + sin(a) * R * 0.97))
}
ctx.strokePath()
ctx.restoreGState()

// Face.
let F = R * 0.82
ctx.saveGState()
ctx.addEllipse(in: circle(F)); ctx.clip()
radial([c(0xF7F9FB), c(0xC9CFD7), c(0xA1A8B2)], F, focus: CGPoint(x: center.x - F * 0.3, y: center.y - F * 0.35))
ctx.restoreGState()
ctx.setStrokeColor(c(0x7A818B, 0.6)); ctx.setLineWidth(R * 0.02)
ctx.strokeEllipse(in: circle(F))
ctx.setStrokeColor(c(0xFFFFFF, 0.6)); ctx.setLineWidth(R * 0.012)
ctx.strokeEllipse(in: circle(F - R * 0.03))

// Stamped cent sign: a light edge below-right and dark fill read as pressed in.
func drawCent(color: CGColor, offset: CGFloat) {
    let size = F * 1.4
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "¢", attributes: attrs))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.saveGState()
    // Undo the y-down flip for text, centered on the glyph's own bounds.
    ctx.translateBy(x: center.x + offset, y: center.y + offset)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}
drawCent(color: c(0xFFFFFF, 0.75), offset: F * 0.018)
drawCent(color: c(0x5D646E, 0.92), offset: 0)

// Shine.
ctx.saveGState()
ctx.addEllipse(in: circle(R)); ctx.clip()
let shine = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0.38), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: center.x - R, y: center.y - R), end: CGPoint(x: center.x, y: center.y), options: [])
ctx.restoreGState()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
