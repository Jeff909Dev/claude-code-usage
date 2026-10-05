#!/usr/bin/env swift
// Draws the app icon at every iconset size and builds Resources/AppIcon.icns with iconutil: a usage gauge in Claude
// orange on a dark tile. Run from the repo root: swift scripts/make-icon.swift
//
// The tile fills the whole canvas. macOS 26 rounds it with its own mask, and puts an icon with transparent corners or
// margins (the macOS 11–15 layout) inside a grey tile instead; macOS 14 and 15 show it with square corners.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    context.setFillColor(color(0x262624))
    context.fill(rect)

    // A faint light from above.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xffffff, 0.07), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY),
                               options: [])

    // The gauge: a 270° track open at the bottom, filled two thirds of the way.
    let center = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.01)
    let radius = rect.width * 0.29
    let start = CGFloat.pi * 5 / 4
    let sweep = CGFloat.pi * 3 / 2
    context.setLineWidth(rect.width * 0.095)
    context.setLineCap(.round)
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
    context.setStrokeColor(color(0xd97757, 0.2))
    context.strokePath()
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep * 0.68, clockwise: true)
    context.setStrokeColor(color(0xd97757))
    context.strokePath()

    // The hub.
    let hub = rect.width * 0.055
    context.setFillColor(color(0xd97757))
    context.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))

    return context.makeImage()!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let url = iconset.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, draw(size: points * scale), nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(name)") }
    }
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
