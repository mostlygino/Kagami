// Fits a finished icon tile onto the macOS icon grid and writes the icon set.
//
//   swiftc -O scripts/fit-icon.swift -o /tmp/fit-icon
//   /tmp/fit-icon <tile.png> <AppIcon.iconset|AppIcon.appiconset> [--png <out-1024.png>]
//
// macOS 26 shows an icon as it is only when its outline is the system's own:
// a rounded square 824 px wide, 100 px in on the 1024 canvas, corner radius
// about 185, with the soft shadow under it. Anything else, a tile 860 px wide
// or with corners of its own, it shrinks and sets on a light grey plate. This
// takes the tile (any opaque artwork on transparency), scales it uniformly to
// overfill that square by OVERSCAN px a side so its own rounder corners fall
// outside, aligns it to the top (what is cut is the shadow baked under the
// tile and a few px of rim), clips it to the system outline and draws the
// system shadow. The geometry and the shadow are Shīru's renderer's, whose
// icon macOS shows unplated.
//
// Every size 16 to 512 at 1x and 2x is scaled down from the 1024. An
// .appiconset also gets its Contents.json.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let overscan: CGFloat = 10
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fit-icon: \(message)\n".utf8)); exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: fit-icon <tile.png> <AppIcon.iconset|AppIcon.appiconset> [--png <out.png>]") }
let input = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
let pngOut = args.firstIndex(of: "--png").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(input.path)") }

func context(_ size: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
    ctx.interpolationQuality = .high
    return ctx
}

// The tile's opaque body, so a transparent margin or a baked shadow does not count.
let w = image.width, h = image.height
let probe = context(max(w, h))
probe.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let data = probe.data else { fail("no pixels") }
let bytes = data.bindMemory(to: UInt8.self, capacity: probe.bytesPerRow * probe.height)
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    let row = bytes + y * probe.bytesPerRow
    for x in 0..<w where row[x * 4 + 3] > 240 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { fail("no opaque tile in \(input.path)") }
// Context rows run bottom up; the crop wants top-down image coordinates.
let probeTop = probe.height - h
let body = CGRect(x: minX, y: probe.height - 1 - maxY - probeTop, width: maxX - minX + 1, height: maxY - minY + 1)
guard let tile = image.cropping(to: body) else { fail("cannot crop") }

// The 1024 master.
let canvas = context(1024)
let scale = (tileRect.width + 2 * overscan) / CGFloat(tile.width)
let drawn = CGSize(width: CGFloat(tile.width) * scale, height: CGFloat(tile.height) * scale)
// Top-aligned: y is from the bottom in Core Graphics.
let place = CGRect(x: tileRect.minX - overscan, y: tileRect.maxY + overscan - drawn.height,
                   width: drawn.width, height: drawn.height)
// The rim colour, so no corner pixel inside the outline is ever empty.
let rimContext = context(1)
rimContext.draw(tile, in: CGRect(x: -CGFloat(tile.width) / 2 + 0.5, y: -CGFloat(tile.height) + 3,
                                 width: CGFloat(tile.width), height: CGFloat(tile.height)))
let rimBytes = rimContext.data!.bindMemory(to: UInt8.self, capacity: 4)
let rim = CGColor(srgbRed: CGFloat(rimBytes[0]) / 255, green: CGFloat(rimBytes[1]) / 255,
                  blue: CGFloat(rimBytes[2]) / 255, alpha: 1)
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.3))
canvas.addPath(tilePath); canvas.setFillColor(rim); canvas.fillPath()
canvas.restoreGState()
canvas.saveGState()
canvas.addPath(tilePath); canvas.clip()
canvas.setFillColor(rim); canvas.fill(tileRect)
canvas.draw(tile, in: place)
canvas.restoreGState()
guard let master = canvas.makeImage() else { fail("cannot render") }

func write(_ image: CGImage, _ url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

func scaled(_ size: Int) -> CGImage {
    let ctx = context(size)
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var entries: [String] = []
for point in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(point)x\(point)\(factor == 2 ? "@2x" : "").png"
        write(point * factor == 1024 ? master : scaled(point * factor), outDir.appendingPathComponent(name))
        entries.append("""
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(factor)x",
              "size" : "\(point)x\(point)"
            }
        """)
    }
}
if outDir.pathExtension == "appiconset" {
    let json = "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
    try? json.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
if let pngOut { write(master, pngOut) }
print("fit-icon: \(input.lastPathComponent) -> \(outDir.lastPathComponent), scale \(String(format: "%.3f", scale))")
