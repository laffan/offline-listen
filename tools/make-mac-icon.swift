#!/usr/bin/env swift
//
// Generates the macOS app-icon PNGs from the 1024×1024 iOS artwork.
//
//   tools/make-mac-icon.swift
//
// iOS and macOS want different *pictures*, not just different sizes. An iOS
// icon is full-bleed square art that the system masks into a squircle at draw
// time; macOS does no masking at all, so handing it the same square gives a
// hard-edged tile that looks nothing like its neighbours in the Dock — or, when
// the catalog has no `mac` entries at all, nothing.
//
// So the Mac icon is baked here, to Apple's proportions: the art is rounded and
// inset to 824×824 within a transparent 1024×1024 canvas, which is what gives
// every Mac icon its shared silhouette and optical size. Everything else is
// downscales of that one rendering.
//
// Re-run after changing AppIcon.png; the output is committed, not built.

import AppKit
import Foundation

let assetPath = "OfflineListen/Assets.xcassets/AppIcon.appiconset"
let sourceName = "AppIcon.png"

// Apple's Big Sur-and-later grid: 824pt of art centred in a 1024pt canvas, with
// a corner radius that's 2/9 of the art's width.
let canvas: CGFloat = 1024
let artwork: CGFloat = 824
let cornerRadius: CGFloat = artwork * 2 / 9

/// One file per catalog entry — ten of them, deliberately, even though three
/// pixel sizes appear twice (32px is both 16@2x and 32@1x, and so on).
///
/// Sharing a filename between two entries looks tidier and silently breaks the
/// icon: `actool` emits no warning, but the compiled `.icns` comes out holding
/// only four of the ten sizes. Distinct names per entry is what makes all ten
/// survive, so the duplicate bytes are the point.
let entries: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

func filename(size: Int, scale: Int) -> String {
    "mac-\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
}

let fileManager = FileManager.default
let assetURL = URL(fileURLWithPath: assetPath)
let sourceURL = assetURL.appendingPathComponent(sourceName)

guard let source = NSImage(contentsOf: sourceURL) else {
    print("error: couldn't read \(sourceURL.path). Run this from the repo root.")
    exit(1)
}

/// The rounded, inset 1024×1024 master every size is derived from.
func renderMaster() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = (canvas - artwork) / 2
    let box = NSRect(x: inset, y: inset, width: artwork, height: artwork)
    // Clip first, then draw the art through it: the source is square and
    // full-bleed, so the rounded rect is what shapes it.
    let mask = NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius)
    mask.addClip()
    source.draw(in: box,
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, pixels: Int, to url: URL) throws {
    let scaled = NSBitmapImageRep(bitmapDataPlanes: nil,
                                  pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    scaled.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
             from: NSRect(x: 0, y: 0, width: canvas, height: canvas),
             operation: .copy, fraction: 1.0,
             respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()

    guard let data = scaled.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-mac-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "couldn't encode \(pixels)px PNG"])
    }
    try data.write(to: url)
}

// Clear out any previous generation so a renamed scheme can't leave orphans.
for existing in (try? fileManager.contentsOfDirectory(atPath: assetURL.path)) ?? []
where existing.hasPrefix("mac-") && existing.hasSuffix(".png") {
    try? fileManager.removeItem(at: assetURL.appendingPathComponent(existing))
}

let master = renderMaster()
for entry in entries {
    let name = filename(size: entry.size, scale: entry.scale)
    try write(master, pixels: entry.size * entry.scale,
              to: assetURL.appendingPathComponent(name))
    print("wrote \(name) (\(entry.size * entry.scale)px)")
}

// The catalog: the original iOS entry untouched, plus the ten macOS ones.
let contents = """
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "filename" : "mac-16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "mac-16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "mac-32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "mac-32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "mac-128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "mac-128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "mac-256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "mac-256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "mac-512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "mac-512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: assetURL.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)
print("wrote Contents.json with the macOS entries")
