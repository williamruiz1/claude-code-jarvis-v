#!/usr/bin/env swift
// Generates Resources/AppIcon.icns from scratch using Core Graphics.
// Run from the repo root:  swift scripts/generate_icon.swift
//
// Style brief: clean waveform-on-dark, brand-coherent with the menu-bar
// SF Symbol "waveform.path.ecg". Single-color rounded-rect background +
// stylized ECG/heartbeat waveform inscribed in the foreground.

import AppKit
import CoreGraphics

// macOS .icns recipe: produce PNGs at all icon sizes (1x + 2x for retina),
// drop them into a temporary .iconset directory, then run `iconutil -c icns`.
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

let repoRoot = FileManager.default.currentDirectoryPath
let iconset = (repoRoot as NSString).appendingPathComponent("Resources/AppIcon.iconset")
let outputIcns = (repoRoot as NSString).appendingPathComponent("Resources/AppIcon.icns")

// Clean the iconset dir so stale entries don't pollute the build.
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func renderIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let bpc = 8
    let bpr = size * 4
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: bpc, bytesPerRow: bpr,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("CGContext failed at size \(size)")
    }

    // 1. Rounded-rect background — deep, slightly cool charcoal, with a
    //    subtle vertical gradient so it feels dimensional, not flat.
    let bgInset: CGFloat = max(1, s * 0.06)
    let bgRect = CGRect(x: bgInset, y: bgInset, width: s - 2*bgInset, height: s - 2*bgInset)
    let radius: CGFloat = s * 0.22
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let topColor   = CGColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1.0) // slate-blue charcoal
    let bottomColor = CGColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1.0)
    if let gradient = CGGradient(colorsSpace: cs, colors: [topColor, bottomColor] as CFArray,
                                 locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: s),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    // 2. Waveform: an ECG-shaped polyline centered horizontally. The shape
    //    mimics SF Symbols' waveform.path.ecg — a flat baseline, a tall
    //    R-spike, a short overshoot, then back to baseline.
    ctx.saveGState()
    let strokeWidth: CGFloat = max(1, s * 0.045)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Soft sky-mint stroke so it pops on the dark bg without screaming.
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.92, blue: 0.78, alpha: 1.0))

    // Define the waveform points in normalized [0,1] coordinates relative to
    // the inner padding box, then convert.
    let pad: CGFloat = s * 0.18
    let innerRect = CGRect(x: pad, y: pad, width: s - 2*pad, height: s - 2*pad)
    let baselineY = innerRect.midY

    // Six-point polyline: [start] [Q dip] [R spike] [S dip] [post-S baseline] [end]
    // Heights are fractions of innerRect.height.
    let points: [(x: CGFloat, y: CGFloat)] = [
        (0.00, 0.50),   // start, baseline
        (0.20, 0.50),   // baseline pre-Q
        (0.30, 0.62),   // Q dip (slight up)
        (0.42, 0.10),   // R spike (deep down because y inverts in our space; but we'll render top→bottom)
        (0.50, 0.92),   // post-spike up
        (0.58, 0.50),   // back to baseline
        (1.00, 0.50),   // tail
    ]

    // We want the spike to go UP visually. CG y-axis goes up = larger y, so
    // "0.92" in our normalized coords = top of inner box. Map accordingly.
    func toCG(_ p: (x: CGFloat, y: CGFloat)) -> CGPoint {
        return CGPoint(
            x: innerRect.minX + innerRect.width * p.x,
            y: innerRect.minY + innerRect.height * p.y
        )
    }

    ctx.beginPath()
    ctx.move(to: toCG(points[0]))
    for p in points.dropFirst() { ctx.addLine(to: toCG(p)) }
    ctx.strokePath()

    // 3. Subtle baseline ghost line through the middle to anchor the eye.
    ctx.setLineWidth(max(0.5, s * 0.012))
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.92, blue: 0.78, alpha: 0.20))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: innerRect.minX, y: baselineY))
    ctx.addLine(to: CGPoint(x: innerRect.minX + innerRect.width * 0.20, y: baselineY))
    ctx.move(to: CGPoint(x: innerRect.minX + innerRect.width * 0.58, y: baselineY))
    ctx.addLine(to: CGPoint(x: innerRect.maxX, y: baselineY))
    ctx.strokePath()

    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("makeImage failed") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    return png
}

print("==> rendering icon variants into \(iconset)")
for entry in sizes {
    let png = renderIcon(size: entry.px)
    let path = (iconset as NSString).appendingPathComponent(entry.name)
    try png.write(to: URL(fileURLWithPath: path))
    print("    \(entry.name) — \(entry.px)px (\(png.count) bytes)")
}

// 4. Convert iconset → .icns
print("==> running iconutil")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", outputIcns, iconset]
try task.run()
task.waitUntilExit()
if task.terminationStatus != 0 {
    fputs("iconutil failed (exit \(task.terminationStatus))\n", stderr)
    exit(1)
}
print("==> wrote \(outputIcns)")
