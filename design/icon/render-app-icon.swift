// Phone Lockbox app icon source (design language v1, docs/design-language.md).
// Usage: cd <scratch dir> && swift <repo>/design/icon/render-app-icon.swift
//        then copy final.png to PhoneLockbox/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import AppKit
import CoreGraphics

// Renders Phone Lockbox app icon concepts at 1024×1024 (top-left origin).
let S: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func makeContext() -> CGContext {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1) // top-left origin
    return ctx
}

func linear(_ ctx: CGContext, _ path: CGPath?, _ c: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    if let path { ctx.addPath(path); ctx.clip() }
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: c as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ c: [CGColor]) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: c as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func background(_ ctx: CGContext) {
    linear(ctx, nil, [rgb(0x1D2150), rgb(0x0B0E22)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: S))
    radial(ctx, center: CGPoint(x: 512, y: 470), radius: 520, [rgb(0x8C7CF0, 0.28), rgb(0x8C7CF0, 0)])
}

/// Crescent: a disc of radius r at c, minus a disc offset by `off`, radius r2.
func crescent(center c: CGPoint, r: CGFloat, off: CGPoint, r2: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    p.addEllipse(in: CGRect(x: c.x + off.x - r2, y: c.y + off.y - r2, width: 2 * r2, height: 2 * r2))
    return p // even-odd fill
}

func clipCrescent(_ ctx: CGContext, center c: CGPoint, r: CGFloat, off: CGPoint, r2: CGFloat) {
    let outside = CGMutablePath()
    outside.addRect(CGRect(x: -10, y: -10, width: S + 20, height: S + 20))
    outside.addEllipse(in: CGRect(x: c.x + off.x - r2, y: c.y + off.y - r2, width: 2 * r2, height: 2 * r2))
    ctx.addPath(outside); ctx.clip(using: .evenOdd)
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
}

func save(_ ctx: CGContext, _ name: String) {
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
}

let lavTop = rgb(0xD9CCFF), lavBottom = rgb(0xA996F2), navy = rgb(0x12153A)

// Concept A — padlock whose keyhole is a crescent moon.
do {
    let ctx = makeContext(); background(ctx)
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 1.22, y: 1.22); ctx.translateBy(x: -512, y: -526)
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: 382, y: 500))
    shackle.addLine(to: CGPoint(x: 382, y: 390))
    shackle.addArc(center: CGPoint(x: 512, y: 390), radius: 130, startAngle: .pi, endAngle: 0, clockwise: false)
    shackle.addLine(to: CGPoint(x: 642, y: 500))
    ctx.saveGState()
    ctx.addPath(shackle); ctx.setLineWidth(76); ctx.setLineCap(.round); ctx.replacePathWithStrokedPath(); ctx.clip()
    linear(ctx, nil, [rgb(0xC9BBFA), rgb(0x9C89EA)], from: CGPoint(x: 0, y: 240), to: CGPoint(x: 0, y: 520))
    ctx.restoreGState()
    let body = CGPath(roundedRect: CGRect(x: 292, y: 470, width: 440, height: 360), cornerWidth: 84, cornerHeight: 84, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: rgb(0x05061A, 0.55))
    ctx.addPath(body); ctx.setFillColor(lavBottom); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    linear(ctx, body, [lavTop, lavBottom], from: CGPoint(x: 0, y: 470), to: CGPoint(x: 0, y: 830))
    ctx.saveGState(); clipCrescent(ctx, center: CGPoint(x: 500, y: 650), r: 96, off: CGPoint(x: 50, y: -38), r2: 84)
    ctx.setFillColor(navy); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S)); ctx.restoreGState()
    save(ctx, "final.png")
}

