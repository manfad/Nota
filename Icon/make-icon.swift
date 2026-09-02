#!/usr/bin/env swift
//
//  make-icon.swift — build Nota.icns from the source artwork.
//
//  Reads  Icon/logo.png (1024x1024 square artwork, no alpha)
//  Writes Icon/Nota.iconset/*.png, Icon/Nota.icns,
//         Icon/preview-512.png, Icon/preview-32.png
//
//  Run:   swift Icon/make-icon.swift        (from the repo root)
//         ./Icon/make-icon.swift            (it is executable)
//
//  The artwork is masked into the standard macOS app-icon tile: a continuous
//  ("squircle") rounded square of 824x824 inset 100pt inside a 1024x1024
//  canvas, corner radius 185.4 (22.5% of the tile). The margin stays
//  transparent so the icon sits at the same visual size as other Dock icons.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Geometry (Apple's macOS icon grid, expressed on a 1024 canvas)

let canvas: CGFloat = 1024
let tileInset: CGFloat = 100          // transparent margin on every side
let tileSide: CGFloat = 824           // 80.5% of the canvas
let cornerRadius: CGFloat = 185.4     // 22.5% of the tile side

// MARK: - Paths

let iconDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let logoURL = iconDir.appendingPathComponent("logo.png")
let iconsetURL = iconDir.appendingPathComponent("Nota.iconset")
let icnsURL = iconDir.appendingPathComponent("Nota.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

// MARK: - Load the artwork

guard let source = CGImageSourceCreateWithURL(logoURL as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read \(logoURL.path)")
}

// MARK: - Render one tile at a given pixel size

/// Draws the artwork through the squircle clip into a square bitmap of `px`
/// points a side, aspect-filled and centre-cropped so it is never distorted.
func renderTile(px: Int) -> CGImage {
    let side = CGFloat(px)
    let scale = side / canvas

    guard let ctx = CGContext(data: nil,
                              width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("cannot create a \(px)x\(px) bitmap context")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let tile = CGRect(x: tileInset * scale, y: tileInset * scale,
                      width: tileSide * scale, height: tileSide * scale)

    // Apple's continuous-corner squircle, straight from SwiftUI.
    let squircle = Path(roundedRect: tile,
                        cornerRadius: cornerRadius * scale,
                        style: .continuous).cgPath
    ctx.addPath(squircle)
    ctx.clip()

    // Aspect-fill the tile with the artwork, centred.
    let iw = CGFloat(logo.width), ih = CGFloat(logo.height)
    let fill = max(tile.width / iw, tile.height / ih)
    let dw = iw * fill, dh = ih * fill
    ctx.draw(logo, in: CGRect(x: tile.midX - dw / 2, y: tile.midY - dh / 2,
                              width: dw, height: dh))

    guard let out = ctx.makeImage() else { fail("cannot rasterise the \(px)px tile") }
    return out
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot finalise \(url.path)") }
}

// MARK: - Build the iconset

// (point size, scale) -> icon_<point>x<point>[@2x].png
let variants: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for v in variants {
    let px = v.point * v.scale
    let suffix = v.scale == 2 ? "@2x" : ""
    let name = "icon_\(v.point)x\(v.point)\(suffix).png"
    writePNG(renderTile(px: px), to: iconsetURL.appendingPathComponent(name))
    print("  \(name)  (\(px)x\(px))")
}

// MARK: - Previews for review

writePNG(renderTile(px: 512), to: iconDir.appendingPathComponent("preview-512.png"))
writePNG(renderTile(px: 32), to: iconDir.appendingPathComponent("preview-32.png"))
print("  preview-512.png, preview-32.png")

// MARK: - iconutil

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fail("iconutil exited \(iconutil.terminationStatus)")
}

let bytes = (try? FileManager.default.attributesOfItem(atPath: icnsURL.path)[.size] as? Int) ?? 0
print("  Nota.icns  (\(bytes) bytes)")
print("make-icon: done")
