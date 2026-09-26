// Renders the 1024×1024 opaque app icon from the Midnight Original palette.
// Usage: swift DesignGallery/Scripts/make_app_icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "PhoneLockbox/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// LockboxDesignSystem tokens.
let background = rgb(0.035, 0.047, 0.11)
let surfaceRaised = rgb(0.105, 0.125, 0.24)
let primary = rgb(0.95, 0.94, 1.0)
let accent = rgb(0.76, 0.69, 0.98)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
let s = CGFloat(size)

// Background: raised indigo at the top fading into the night background.
let gradient = CGGradient(colorsSpace: space, colors: [surfaceRaised, background] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: s / 2, y: s), end: CGPoint(x: s / 2, y: 0), options: [])

// Soft glow behind the phone.
let glow = CGGradient(colorsSpace: space, colors: [rgb(0.76, 0.69, 0.98, 0.22), rgb(0.76, 0.69, 0.98, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s / 2, y: s * 0.5), startRadius: 0,
                       endCenter: CGPoint(x: s / 2, y: s * 0.5), endRadius: s * 0.45, options: [])

// Phone outline.
let phone = CGRect(x: s * 0.32, y: s * 0.19, width: s * 0.36, height: s * 0.62)
ctx.setStrokeColor(accent)
ctx.setLineWidth(s * 0.034)
ctx.addPath(CGPath(roundedRect: phone, cornerWidth: s * 0.075, cornerHeight: s * 0.075, transform: nil))
ctx.strokePath()

// Crescent moon: a full disc with an offset disc cut away.
let moonCenter = CGPoint(x: s * 0.5, y: s * 0.52)
let moonRadius = s * 0.105
let moonDisc = CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius, width: moonRadius * 2, height: moonRadius * 2)
ctx.saveGState()
ctx.addEllipse(in: moonDisc)
ctx.clip()
ctx.addRect(moonDisc.insetBy(dx: -2, dy: -2))
ctx.addEllipse(in: CGRect(x: moonCenter.x - moonRadius * 0.45, y: moonCenter.y - moonRadius * 0.55, width: moonRadius * 2, height: moonRadius * 2))
ctx.setFillColor(primary)
ctx.fillPath(using: .evenOdd)
ctx.restoreGState()

// Two small stars inside the screen.
ctx.setFillColor(rgb(0.95, 0.94, 1.0, 0.8))
for (x, y, r) in [(0.60, 0.63, 0.013), (0.565, 0.68, 0.008)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.fillEllipse(in: CGRect(x: s * x - s * r, y: s * y - s * r, width: s * r * 2, height: s * r * 2))
}

// Home indicator.
ctx.setFillColor(accent)
ctx.addPath(CGPath(roundedRect: CGRect(x: s * 0.45, y: s * 0.245, width: s * 0.10, height: s * 0.016),
                   cornerWidth: s * 0.008, cornerHeight: s * 0.008, transform: nil))
ctx.fillPath()

let url = URL(fileURLWithPath: output)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write \(output)") }
print("Wrote \(output)")
