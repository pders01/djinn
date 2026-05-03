#!/usr/bin/env swift

// generate-icon.swift — render the 1024x1024 master PNG for Djinn.icns.
// Runs as `swift generate-icon.swift <output.png>`. The bash driver
// (scripts/generate-icon.sh) takes that PNG, fans out to the macOS
// iconset sizes via `sips`, and packs the result with `iconutil`.
//
// Design: dark navy rounded-square (Big Sur+ corner ratio ~22%), white
// Arabic brand glyph "جن" (jīm + nūn = "djinn") centered + a soft
// inner highlight ring for depth. CoreText shapes the contextual
// joining; no HarfBuzz dependency. Same brand mark drives the menubar
// idle state, just rendered larger here.

import Cocoa

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: generate-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    FileHandle.standardError.write("no graphics context\n".data(using: .utf8)!)
    exit(1)
}

// Rounded-square mask. Apple's macOS Big Sur+ icon shape uses a
// continuous-curvature superellipse with corner ratio ~22.37%; a plain
// rounded rect at 22% is visually indistinguishable at icon sizes and
// is what every third-party tool uses.
let corner = size * 0.2237
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

// Vertical gradient: theme.background (top) → palette[8] dim (bottom).
// Same colors the chrome surface uses, so the icon reads as part of
// the same design system.
let topColor = CGColor(red: 0.102, green: 0.102, blue: 0.118, alpha: 1)
let botColor = CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
let cs = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorsSpace: cs, colors: [topColor, botColor] as CFArray, locations: [0, 1])!

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)
ctx.restoreGState()

// Soft inner stroke for elevation.
ctx.addPath(bgPath)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

// Brand glyph. NSAttributedString.draw uses CoreText, which handles
// the contextual Arabic joining for jīm + nūn.
let fontSize = size * 0.55
let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
let glyph = NSAttributedString(string: "جن", attributes: [
    .font: font,
    .foregroundColor: NSColor.white,
])
let glyphSize = glyph.size()
let glyphPoint = NSPoint(
    x: (size - glyphSize.width) / 2,
    y: (size - glyphSize.height) / 2 - size * 0.02 // tiny optical down-shift
)
glyph.draw(at: glyphPoint)

img.unlockFocus()

// Snapshot at native resolution. NSBitmapImageRep(focusedViewRect:)
// only works while focus is locked; instead rasterize from the NSImage
// representation.
let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let rep = NSBitmapImageRep(cgImage: cgImg)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
