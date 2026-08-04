#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-dmg-background.swift <output.png>\n", stderr)
    exit(64)
}

let size = NSSize(width: 600, height: 360)
let image = NSImage(size: size)
image.lockFocus()

let canvas = NSRect(origin: .zero, size: size)
NSGradient(colors: [
    NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1),
    NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.99, alpha: 1),
])?.draw(in: canvas, angle: 0)

let glow = NSBezierPath(ovalIn: NSRect(x: 150, y: 60, width: 300, height: 300))
NSColor(calibratedRed: 0.35, green: 0.38, blue: 0.96, alpha: 0.10).setFill()
glow.fill()

let title = "Install MacDrop"
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .bold),
    .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
]
let titleSize = title.size(withAttributes: titleAttributes)
title.draw(
    at: NSPoint(x: (size.width - titleSize.width) / 2, y: 300),
    withAttributes: titleAttributes
)

let subtitle = "Drag MacDrop into Applications"
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 0.72),
]
let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
subtitle.draw(
    at: NSPoint(x: (size.width - subtitleSize.width) / 2, y: 272),
    withAttributes: subtitleAttributes
)

let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 240, y: 175))
arrow.line(to: NSPoint(x: 360, y: 175))
arrow.move(to: NSPoint(x: 338, y: 195))
arrow.line(to: NSPoint(x: 360, y: 175))
arrow.line(to: NSPoint(x: 338, y: 155))
NSColor(calibratedRed: 0.29, green: 0.65, blue: 1, alpha: 0.9).setStroke()
arrow.stroke()

image.unlockFocus()

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width * 2),
    pixelsHigh: Int(size.height * 2),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("could not allocate DMG background\n", stderr)
    exit(1)
}
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: canvas)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not render DMG background\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
