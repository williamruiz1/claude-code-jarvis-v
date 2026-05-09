#!/usr/bin/env swift
// Generates Resources/AppIcon.icns from scratch using Core Graphics.
// Run from the repo root:  swift scripts/generate_icon.swift
//
// Brand brief (JARVIS V):
//   - Background: deep slate-charcoal (#1A1A1F → #0E0F14 vertical gradient).
//   - Foreground: clean monoline ECG-style waveform in the brand amber
//     accent (#E89A3F).
//   - Bottom-right: a small "JV" monogram glyph — readable at 256+, fades to
//     a tasteful smudge at 32 / 16 (which is the right behavior; the
//     waveform alone carries identity at the smallest sizes).
//
// All hex values are mirrored in Sources/VoiceModeMenuBar/BrandingTheme.swift
// (the in-app theme) so the icon and the in-app HUD share one palette.

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

// MARK: - Brand palette (mirrored in BrandingTheme.swift)

// Deep slate-charcoal background gradient.
let bgTopColor    = CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0) // ~#1A1A1F
let bgBottomColor = CGColor(red: 0.055, green: 0.060, blue: 0.078, alpha: 1.0) // ~#0E0F14

// Brand amber #E89A3F.
let amberColor    = CGColor(red: 0xE8/255.0, green: 0x9A/255.0, blue: 0x3F/255.0, alpha: 1.0)
// Slightly hotter highlight for the spike apex glow.
let amberHotColor = CGColor(red: 1.00, green: 0.74, blue: 0.42, alpha: 1.0)

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

    // 1. Rounded-rect background — deep slate-charcoal gradient. macOS app
    //    icons should NOT include the squircle mask themselves at modern
    //    sizes, but we keep a generous corner radius so the .icns reads well
    //    in both Finder list view (raw) and Dock (system-masked).
    let bgInset: CGFloat = max(1, s * 0.06)
    let bgRect = CGRect(x: bgInset, y: bgInset, width: s - 2*bgInset, height: s - 2*bgInset)
    let radius: CGFloat = s * 0.22
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: cs,
                                 colors: [bgTopColor, bgBottomColor] as CFArray,
                                 locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: s),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    // 2. Waveform: monoline ECG polyline in brand amber, centered horizontally.
    //    The shape mimics SF Symbols' waveform.path.ecg — a flat baseline,
    //    a tall R-spike, a short overshoot, then back to baseline.
    ctx.saveGState()
    let strokeWidth: CGFloat = max(1, s * 0.05)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(amberColor)

    let pad: CGFloat = s * 0.18
    let innerRect = CGRect(x: pad, y: pad, width: s - 2*pad, height: s - 2*pad)
    let baselineY = innerRect.midY

    // Six-point polyline (normalized [0,1] in innerRect).
    let points: [(x: CGFloat, y: CGFloat)] = [
        (0.00, 0.50),   // start, baseline
        (0.20, 0.50),   // baseline pre-Q
        (0.30, 0.62),   // Q dip (slight up)
        (0.42, 0.10),   // R spike — top of inner box
        (0.50, 0.92),   // post-spike up (CG y inverted = below baseline visually)
        (0.58, 0.50),   // back to baseline
        (1.00, 0.50),   // tail
    ]

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

    // 3. Subtle baseline ghost — anchors the eye and reads as a "trace" line.
    ctx.setLineWidth(max(0.5, s * 0.012))
    ctx.setStrokeColor(amberColor.copy(alpha: 0.22) ?? amberColor)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: innerRect.minX, y: baselineY))
    ctx.addLine(to: CGPoint(x: innerRect.minX + innerRect.width * 0.20, y: baselineY))
    ctx.move(to: CGPoint(x: innerRect.minX + innerRect.width * 0.58, y: baselineY))
    ctx.addLine(to: CGPoint(x: innerRect.maxX, y: baselineY))
    ctx.strokePath()

    // 4. Spike apex glow — a small radial highlight at the top of the R-spike.
    //    Helps the icon feel alive without adding clutter.
    let spikePoint = toCG(points[3])
    ctx.saveGState()
    if let glow = CGGradient(colorsSpace: cs,
                             colors: [
                                amberHotColor.copy(alpha: 0.55) ?? amberHotColor,
                                amberHotColor.copy(alpha: 0.0) ?? amberHotColor,
                             ] as CFArray,
                             locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(glow,
                               startCenter: spikePoint, startRadius: 0,
                               endCenter: spikePoint, endRadius: s * 0.10,
                               options: [])
    }
    ctx.restoreGState()
    ctx.restoreGState()

    // 5. JV monogram — bottom-right, only at sizes where it's legible. Below
    //    64px the monogram becomes visual noise and we omit it entirely.
    if size >= 64 {
        ctx.saveGState()
        let monoSize = s * 0.14
        let monoFont = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .bold)
        let monoColor = NSColor(srgbRed: 0xE8/255.0, green: 0x9A/255.0, blue: 0x3F/255.0,
                                alpha: 0.55)
        let monoAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: monoColor,
            .kern: monoSize * 0.06,
        ]
        let monoString = NSAttributedString(string: "JV", attributes: monoAttrs)
        let monoBounds = monoString.size()
        let monoOrigin = CGPoint(
            x: bgRect.maxX - monoBounds.width - s * 0.10,
            y: bgRect.minY + s * 0.07
        )

        // Push an NSGraphicsContext so NSAttributedString.draw renders into
        // our CGContext rather than whatever the current focused view is.
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        monoString.draw(at: monoOrigin)
        NSGraphicsContext.restoreGraphicsState()

        ctx.restoreGState()
    }

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

// 6. Convert iconset → .icns
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
