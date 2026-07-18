#!/usr/bin/env swift
//
// make-appicon.swift — composite the freeq glyph onto a dark rounded-rect
// plate and emit every AppIcon size.
//
// Why: the shipped icon was a bright glyph on full transparency, so macOS
// composited it directly over the Dock/Finder background and the logo
// colors "bled" into whatever was behind it. A solid dark plate (matching
// the app's #0a0a1a dark theme) gives the glyph a consistent ground.
//
// Geometry follows Apple's Big Sur macOS grid: for a 1024 canvas the
// rounded-square body is 824×824 (100px margin for the system shadow),
// corner radius 185.4px. The glyph sits at ~60% of the body, centered.
//
// Usage (from repo root or anywhere):
//   swift freeq-macos/scripts/make-appicon.swift
// Reads freeq-macos/scripts/icon-src/glyph.png; writes the appiconset PNGs.

import AppKit
import CoreGraphics

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let glyphURL = scriptURL.appendingPathComponent("icon-src/glyph.png")
let outDir = scriptURL
    .deletingLastPathComponent()
    .appendingPathComponent("freeq-macos/Assets.xcassets/AppIcon.appiconset")

guard let glyphImg = NSImage(contentsOf: glyphURL),
      let glyphCG = glyphImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot load glyph at \(glyphURL.path)\n".data(using: .utf8)!)
    exit(1)
}

/// Render one icon at `px` × `px`.
func renderIcon(px: Int) -> Data? {
    let size = CGFloat(px)
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Big Sur grid scaled to this size.
    let bodyInset = size * (100.0 / 1024.0)
    let cornerRadius = size * (185.4 / 1024.0)
    let bodyRect = CGRect(x: bodyInset, y: bodyInset,
                          width: size - 2 * bodyInset, height: size - 2 * bodyInset)

    // Rounded-rect clip for the dark plate.
    let path = CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius,
                      cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Dark vertical gradient (top slightly lighter) matching the app theme.
    let colors = [
        CGColor(red: 0.078, green: 0.078, blue: 0.180, alpha: 1.0), // #14142e
        CGColor(red: 0.039, green: 0.039, blue: 0.094, alpha: 1.0), // #0a0a18
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0), options: [])
    }

    // Glyph centered at ~60% of the body.
    let glyphFrac: CGFloat = 0.60
    let glyphSize = bodyRect.width * glyphFrac
    let glyphRect = CGRect(
        x: bodyRect.midX - glyphSize / 2,
        y: bodyRect.midY - glyphSize / 2,
        width: glyphSize, height: glyphSize
    )
    ctx.interpolationQuality = .high
    ctx.draw(glyphCG, in: glyphRect)

    guard let out = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: out)
    return rep.representation(using: .png, properties: [:])
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for px in sizes {
    guard let data = renderIcon(px: px) else {
        FileHandle.standardError.write("failed to render \(px)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outDir.appendingPathComponent("icon_\(px).png")
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent)")
}
print("done")
