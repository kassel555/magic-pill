#!/usr/bin/env swift

// Generates the app icon as a 1024×1024 PNG.
//
// Checked in as a script rather than a binary someone has to reverse-engineer:
// the icon is part of the design system, and the palette here must stay in step
// with `MagicPillKit/Design/Palette.swift`.
//
//   swift Tools/GenerateAppIcon.swift
//
// The mark is the manifesto's thesis rather than the app's name: a timeline —
// a quiet vertical rule with three nodes, the present one emphasised. Not a
// pill, not a cross, nothing clinical. It reads at 40pt because it is three
// shapes and one line.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Sage, from the palette — the app's accent.
let sageLight = srgb(0x8CA890)
let sageDeep = srgb(0x5E7A63)
let cream = srgb(0xFBFAF8)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create bitmap context")
}

// Background: a soft vertical gradient. Flat colour looks inert at icon scale;
// this gives depth without the glossy look the manifesto rejects.
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [sageLight, sageDeep] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// The timeline rule.
let centerX = CGFloat(size) / 2
let ruleWidth: CGFloat = 26
let ruleTop = CGFloat(size) * 0.20
let ruleBottom = CGFloat(size) * 0.80

context.setFillColor(cream.copy(alpha: 0.40)!)
let rule = CGPath(
    roundedRect: CGRect(
        x: centerX - ruleWidth / 2,
        y: ruleTop,
        width: ruleWidth,
        height: ruleBottom - ruleTop
    ),
    cornerWidth: ruleWidth / 2,
    cornerHeight: ruleWidth / 2,
    transform: nil
)
context.addPath(rule)
context.fillPath()

// Three nodes. The middle one is solid and larger: the present moment, which
// is what the timeline is actually for.
func node(atY y: CGFloat, radius: CGFloat, alpha: CGFloat) {
    context.setFillColor(cream.copy(alpha: alpha)!)
    context.addEllipse(in: CGRect(
        x: centerX - radius,
        y: y - radius,
        width: radius * 2,
        height: radius * 2
    ))
    context.fillPath()
}

node(atY: ruleBottom, radius: 58, alpha: 0.68)
node(atY: ruleTop, radius: 58, alpha: 0.68)

// A ring around the present node, so it reads as "now" rather than just "big".
let presentY = (ruleTop + ruleBottom) / 2
context.setFillColor(sageDeep)
context.addEllipse(in: CGRect(x: centerX - 142, y: presentY - 142, width: 284, height: 284))
context.fillPath()

context.setStrokeColor(cream.copy(alpha: 0.42)!)
context.setLineWidth(18)
context.addEllipse(in: CGRect(x: centerX - 132, y: presentY - 132, width: 264, height: 264))
context.strokePath()

node(atY: presentY, radius: 88, alpha: 1)

guard let image = context.makeImage() else {
    fatalError("Could not render image")
}

let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("MagicPill/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("Could not create image destination at \(outputURL.path)")
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not write PNG")
}

print("Wrote \(outputURL.path)")
