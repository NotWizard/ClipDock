// Original ClipDock artwork: a clipped document resting in an open dock.
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func renderMaster(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    let body = CGRect(x: 84, y: 84, width: 856, height: 856)
    ctx.saveGState()
    ctx.addPath(rounded(body, radius: 190))
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.98, green: 0.32, blue: 0.31, alpha: 1),
                  CGColor(srgbRed: 1.00, green: 0.58, blue: 0.42, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 84), end: CGPoint(x: 512, y: 940), options: [])
    ctx.restoreGState()

    let ink = CGColor(srgbRed: 0.12, green: 0.16, blue: 0.25, alpha: 1)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.13))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.99, blue: 0.96, alpha: 1))
    ctx.addPath(rounded(CGRect(x: 322, y: 354, width: 380, height: 408), radius: 42))
    ctx.fillPath()
    ctx.restoreGState()

    // The clip makes the document recognisable before it reaches the dock.
    ctx.setFillColor(ink)
    ctx.addPath(rounded(CGRect(x: 438, y: 718, width: 148, height: 76), radius: 24))
    ctx.fillPath()
    ctx.setFillColor(CGColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1))
    ctx.addPath(rounded(CGRect(x: 484, y: 744, width: 56, height: 14), radius: 7))
    ctx.fillPath()
    ctx.setFillColor(CGColor(srgbRed: 0.43, green: 0.50, blue: 0.62, alpha: 1))
    ctx.addPath(rounded(CGRect(x: 390, y: 608, width: 244, height: 28), radius: 14))
    ctx.fillPath()
    ctx.addPath(rounded(CGRect(x: 390, y: 538, width: 164, height: 28), radius: 14))
    ctx.fillPath()

    // One open U silhouette carries the 'Dock' in app and menu-bar artwork.
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(64)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 254, y: 426))
    ctx.addLine(to: CGPoint(x: 254, y: 300))
    ctx.addQuadCurve(to: CGPoint(x: 308, y: 246), control: CGPoint(x: 254, y: 246))
    ctx.addLine(to: CGPoint(x: 716, y: 246))
    ctx.addQuadCurve(to: CGPoint(x: 770, y: 300), control: CGPoint(x: 770, y: 246))
    ctx.addLine(to: CGPoint(x: 770, y: 426))
    ctx.strokePath()
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, path: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func writeStatusIcon(paused: Bool, to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 22, height: 22)
    let ctx = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.setLineWidth(1.65)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 3.5, y: 9))
    ctx.addLine(to: CGPoint(x: 3.5, y: 5))
    ctx.addQuadCurve(to: CGPoint(x: 5.5, y: 3), control: CGPoint(x: 3.5, y: 3))
    ctx.addLine(to: CGPoint(x: 16.5, y: 3))
    ctx.addQuadCurve(to: CGPoint(x: 18.5, y: 5), control: CGPoint(x: 18.5, y: 3))
    ctx.addLine(to: CGPoint(x: 18.5, y: 9))
    ctx.strokePath()
    ctx.addPath(rounded(CGRect(x: 6.5, y: 7, width: 9, height: 12), radius: 1.4))
    ctx.strokePath()
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(rounded(CGRect(x: 9, y: 17.5, width: 4, height: 3), radius: 0.8))
    ctx.fillPath()
    if paused {
        ctx.fill(CGRect(x: 8.6, y: 10.5, width: 1.5, height: 4))
        ctx.fill(CGRect(x: 11.9, y: 10.5, width: 1.5, height: 4))
    } else {
        ctx.setLineWidth(1.3)
        ctx.move(to: CGPoint(x: 9, y: 14))
        ctx.addLine(to: CGPoint(x: 13, y: 14))
        ctx.move(to: CGPoint(x: 9, y: 11))
        ctx.addLine(to: CGPoint(x: 11.5, y: 11))
        ctx.strokePath()
    }
    ctx.endPDFPage()
    ctx.closePDF()
}

let master = renderMaster(size: 1024)
let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (pixels, name) in variants { try writePNG(master, pixels: pixels, path: "\(outDir)/\(name).png") }
let buildDirectory = URL(fileURLWithPath: outDir).deletingLastPathComponent()
writeStatusIcon(paused: false, to: buildDirectory.appendingPathComponent("StatusIcon.pdf"))
writeStatusIcon(paused: true, to: buildDirectory.appendingPathComponent("StatusIconPaused.pdf"))
print("ClipDock app and template status icons written")
