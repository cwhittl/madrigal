#!/usr/bin/env swift
// Draws the iOS 27 App Store product page header and search results images
// from the app icon and the iPhone 6.3" screenshots. Opaque PNGs (no alpha
// channel), at the sizes App Store Connect asks for:
//   promo/header.png          3840x1646  (21:9)
//   promo/search-results.png  3840x2560  (3:2)
// Text and key content stay inside Apple's template safe areas:
//   header  x 1097–2743, y 493–1154
//   search  x 836–3004,  y 765–1795
//
// Usage: swift AppStore/make-promo-art.swift   (run capture-screenshots.sh first)

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let shots = root.appendingPathComponent("screenshots/iphone-6.3")
let out = root.appendingPathComponent("promo")
let iconURL = root.deletingLastPathComponent()
    .appendingPathComponent("MadrigalChat/Resources/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png")

let accent = NSColor(srgbRed: 0.557, green: 0.392, blue: 1.0, alpha: 1)
let subtle = NSColor(srgbRed: 0.80, green: 0.76, blue: 0.95, alpha: 1)

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Can't read \(url.path)")
    }
    return image
}

/// A top-left-origin drawing context with no alpha channel.
func canvas(_ width: Int, _ height: Int, draw: (CGContext) -> Void) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw(ctx)
    NSGraphicsContext.current = nil
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ name: String) {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Can't write \(url.path)") }
    print("promo/\(name)  \(image.width)x\(image.height)")
}

/// Deep navy with a soft purple glow, matching the app icon.
func background(_ ctx: CGContext, _ size: CGSize, glowAt glow: CGPoint) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let linear = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.15, green: 0.12, blue: 0.28, alpha: 1),
        CGColor(srgbRed: 0.07, green: 0.06, blue: 0.13, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(linear, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
    let radial = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.557, green: 0.392, blue: 1.0, alpha: 0.38),
        CGColor(srgbRed: 0.557, green: 0.392, blue: 1.0, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(radial, startCenter: glow, startRadius: 0, endCenter: glow,
                           endRadius: size.width * 0.42, options: [])
}

/// Faint outlined speech bubbles near the edges, outside the safe area.
func bubbles(_ ctx: CGContext, _ items: [(CGRect, CGFloat)]) {
    ctx.saveGState()
    ctx.setLineWidth(28)
    for (rect, alpha) in items {
        ctx.setStrokeColor(accent.withAlphaComponent(alpha).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

/// Centered text, shrunk until it fits `maxWidth`. Returns its height.
@discardableResult
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          centerX: CGFloat, top: CGFloat, maxWidth: CGFloat) -> CGFloat {
    var size = size
    var attributed: NSAttributedString
    repeat {
        attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: -size * 0.01,
        ])
        size -= 2
    } while attributed.size().width > maxWidth
    let bounds = attributed.size()
    attributed.draw(at: CGPoint(x: centerX - bounds.width / 2, y: top))
    return bounds.height
}

func roundedImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, radius: CGFloat, shadow: Bool = true) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 40), blur: 120, color: CGColor(gray: 0, alpha: 0.55))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // The context is flipped; flip the image back so it draws upright.
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

/// A phone screenshot with a dark bezel.
func phone(_ ctx: CGContext, _ image: CGImage, x: CGFloat, y: CGFloat, width: CGFloat) {
    let height = width * CGFloat(image.height) / CGFloat(image.width)
    let bezel: CGFloat = width * 0.035
    let outer = CGRect(x: x - bezel, y: y - bezel, width: width + bezel * 2, height: height + bezel * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 50), blur: 140, color: CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: width * 0.17, cornerHeight: width * 0.17, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    ctx.setLineWidth(4)
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: width * 0.17, cornerHeight: width * 0.17, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()
    roundedImage(ctx, image, in: CGRect(x: x, y: y, width: width, height: height), radius: width * 0.14, shadow: false)
}

let icon = loadImage(iconURL)

// MARK: Header — one idea: the app and what it is. No phone; screenshots sit just below.

let header = canvas(3840, 1646) { ctx in
    let size = CGSize(width: 3840, height: 1646)
    background(ctx, size, glowAt: CGPoint(x: 1920, y: 820))
    bubbles(ctx, [
        (CGRect(x: -160, y: 180, width: 900, height: 420), 0.22),
        (CGRect(x: 250, y: 1060, width: 620, height: 300), 0.14),
        (CGRect(x: 3020, y: 240, width: 980, height: 440), 0.18),
        (CGRect(x: 2980, y: 1080, width: 560, height: 270), 0.12),
    ])
    // Safe area: x 1097–2743, y 493–1154 (center 1920, 823).
    let iconSize: CGFloat = 210
    roundedImage(ctx, icon, in: CGRect(x: 1920 - iconSize / 2, y: 500, width: iconSize, height: iconSize), radius: iconSize * 0.225)
    let headline = text("Chat with any AI model", size: 150, weight: .bold, color: .white,
                        centerX: 1920, top: 760, maxWidth: 1600)
    text("Bring your own keys, or run models on your device.", size: 64, weight: .medium, color: subtle,
         centerX: 1920, top: 760 + headline + 30, maxWidth: 1600)
}
save(header, "header.png")

// MARK: Search results — state the obvious: the chat interface, on iPhone.

let search = canvas(3840, 2560) { ctx in
    let size = CGSize(width: 3840, height: 2560)
    background(ctx, size, glowAt: CGPoint(x: 1920, y: 1500))
    bubbles(ctx, [
        (CGRect(x: -200, y: 300, width: 800, height: 380), 0.18),
        (CGRect(x: 3260, y: 360, width: 800, height: 380), 0.18),
    ])
    // Safe area: x 836–3004, y 765–1795. Headline on top, phones below it.
    text("Any model. Your keys. Your device.", size: 140, weight: .bold, color: .white,
         centerX: 1920, top: 790, maxWidth: 2100)
    let width: CGFloat = 640, gap: CGFloat = 150
    let left = loadImage(shots.appendingPathComponent("2-sidebar.png"))
    let middle = loadImage(shots.appendingPathComponent("1-chat.png"))
    let right = loadImage(shots.appendingPathComponent("4-on-device.png"))
    phone(ctx, left, x: 1920 - width * 1.5 - gap, y: 1080, width: width)
    phone(ctx, right, x: 1920 + width * 0.5 + gap, y: 1080, width: width)
    phone(ctx, middle, x: 1920 - width / 2, y: 1010, width: width)
}
save(search, "search-results.png")
