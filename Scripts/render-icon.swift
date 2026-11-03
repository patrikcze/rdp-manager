// Renders the RDP Manager app icon at 1024×1024 and builds Resources/AppIcon.icns.
//   swift Scripts/render-icon.swift
// Original artwork: two stacked session windows (many sessions) on a deep blue squircle; the
// front window shows a remote screen with a pointer (you are in control) and a green
// "connected" light in its title bar.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ context: CGContext, in path: CGPath, colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Work top-down like a design tool.
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

// MARK: Squircle body (Apple's 824 pt grid inside 1024, ~22.5% corner radius)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(body, 186)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x000000, 0.35))
context.addPath(bodyPath)
context.setFillColor(color(0x1B2C7A))
context.fillPath()
context.restoreGState()
linearGradient(context, in: bodyPath, colors: [color(0x3B7BFF), color(0x2442C9), color(0x161F6B)],
               from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
// Soft glow behind the windows.
context.saveGState()
context.addPath(bodyPath)
context.clip()
let glow = CGGradient(colorsSpace: space, colors: [color(0x7FD3FF, 0.45), color(0x7FD3FF, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 540, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 540, y: 470), endRadius: 430, options: [])
context.restoreGState()
// Top sheen.
linearGradient(context, in: roundedRect(body.insetBy(dx: 2, dy: 2), 184),
               colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)],
               from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 420))

// MARK: Back window (another session)
let back = CGRect(x: 312, y: 236, width: 500, height: 360)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0x050A30, 0.35))
context.addPath(roundedRect(back, 44))
context.setFillColor(color(0xFFFFFF, 0.28))
context.fillPath()
context.restoreGState()
context.addPath(roundedRect(back.insetBy(dx: 1.5, dy: 1.5), 43))
context.setStrokeColor(color(0xFFFFFF, 0.45))
context.setLineWidth(3)
context.strokePath()

// MARK: Front window
let front = CGRect(x: 212, y: 336, width: 560, height: 412)
let frontPath = roundedRect(front, 48)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: color(0x040824, 0.55))
context.addPath(frontPath)
context.setFillColor(color(0xF4F7FF))
context.fillPath()
context.restoreGState()
linearGradient(context, in: frontPath, colors: [color(0xFFFFFF), color(0xE3EAFB)],
               from: CGPoint(x: 0, y: front.minY), to: CGPoint(x: 0, y: front.maxY))

// Title bar lights: two neutral, one green "connected".
let lightY = front.minY + 40
for (index, fill) in [color(0xC5CEE3), color(0xC5CEE3), color(0x34D27B)].enumerated() {
    let center = CGPoint(x: front.minX + 46 + CGFloat(index) * 36, y: lightY)
    context.addEllipse(in: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))
    context.setFillColor(fill)
    context.fillPath()
}
// A short title stroke.
context.addPath(roundedRect(CGRect(x: front.minX + 180, y: lightY - 7, width: 170, height: 14), 7))
context.setFillColor(color(0xC9D2E8))
context.fillPath()

// The remote screen.
let screen = CGRect(x: front.minX + 26, y: front.minY + 78, width: front.width - 52, height: front.height - 104)
let screenPath = roundedRect(screen, 26)
linearGradient(context, in: screenPath, colors: [color(0x0B1E5B), color(0x1748B8), color(0x22A6E8)],
               from: CGPoint(x: screen.minX, y: screen.maxY), to: CGPoint(x: screen.maxX, y: screen.minY))
// Gentle horizon waves suggest a desktop without depicting any vendor's wallpaper.
context.saveGState()
context.addPath(screenPath)
context.clip()
for (offset, alpha) in [(0.0, 0.16), (46.0, 0.10)] {
    let wave = CGMutablePath()
    let baseY = screen.maxY - 92 + offset
    wave.move(to: CGPoint(x: screen.minX, y: baseY))
    wave.addCurve(to: CGPoint(x: screen.maxX, y: baseY - 40),
                  control1: CGPoint(x: screen.minX + screen.width * 0.35, y: baseY - 90),
                  control2: CGPoint(x: screen.minX + screen.width * 0.65, y: baseY + 50))
    wave.addLine(to: CGPoint(x: screen.maxX, y: screen.maxY))
    wave.addLine(to: CGPoint(x: screen.minX, y: screen.maxY))
    wave.closeSubpath()
    context.addPath(wave)
    context.setFillColor(color(0xFFFFFF, alpha))
    context.fillPath()
}
context.restoreGState()

// MARK: Pointer — the user's control of the remote screen.
let tip = CGPoint(x: 492, y: 470)
let pointer = CGMutablePath()
pointer.move(to: tip)
pointer.addLine(to: CGPoint(x: tip.x, y: tip.y + 196))
pointer.addLine(to: CGPoint(x: tip.x + 46, y: tip.y + 152))
pointer.addLine(to: CGPoint(x: tip.x + 78, y: tip.y + 222))
pointer.addLine(to: CGPoint(x: tip.x + 110, y: tip.y + 208))
pointer.addLine(to: CGPoint(x: tip.x + 78, y: tip.y + 140))
pointer.addLine(to: CGPoint(x: tip.x + 140, y: tip.y + 140))
pointer.closeSubpath()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: color(0x020617, 0.55))
context.addPath(pointer)
context.setFillColor(color(0xFFFFFF))
context.fillPath()
context.restoreGState()
context.addPath(pointer)
context.setStrokeColor(color(0x0B1E5B))
context.setLineWidth(9)
context.setLineJoin(.round)
context.strokePath()

// MARK: Output
let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
let iconset = root.appending(path: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = root.appending(path: "Resources/AppIcon-1024.png")
try png.write(to: master)

func resized(_ pixels: Int) -> Data {
    let target = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: size, height: size))
        .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return target.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try resized(points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try resized(points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
