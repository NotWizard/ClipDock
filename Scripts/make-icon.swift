// Package the generated app artwork; draw native template marks from its silhouette.
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Artwork/ClipDock-Icon.png")
let data = try Data(contentsOf: source)
guard let master = NSImage(data: data), let bitmap = NSBitmapImageRep(data: data),
      bitmap.pixelsWide == bitmap.pixelsHigh, bitmap.pixelsWide >= 1024, bitmap.hasAlpha else {
    fatalError("App icon master must be a square transparent PNG of at least 1024 pixels")
}

func writePNG(_ image: NSImage, pixels: Int, path: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let inset = CGFloat(pixels) * 0.035
    image.draw(in: NSRect(x: inset, y: inset, width: CGFloat(pixels) - inset * 2, height: CGFloat(pixels) - inset * 2))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func writeStatusIcon(paused: Bool, to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 22, height: 22)
    let ctx = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.setLineWidth(1.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 3.25, y: 9))
    ctx.addLine(to: CGPoint(x: 3.25, y: 5.25))
    ctx.addQuadCurve(to: CGPoint(x: 5, y: 3.5), control: CGPoint(x: 3.25, y: 3.5))
    ctx.addLine(to: CGPoint(x: 17, y: 3.5))
    ctx.addQuadCurve(to: CGPoint(x: 18.75, y: 5.25), control: CGPoint(x: 18.75, y: 3.5))
    ctx.addLine(to: CGPoint(x: 18.75, y: 9))
    ctx.strokePath()

    // The exposed back card and folded front corner identify the generated artwork.
    ctx.move(to: CGPoint(x: 5.75, y: 9))
    ctx.addLine(to: CGPoint(x: 5.75, y: 18))
    ctx.addQuadCurve(to: CGPoint(x: 7.25, y: 19.5), control: CGPoint(x: 5.75, y: 19.5))
    ctx.addLine(to: CGPoint(x: 12.75, y: 19.5))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 9.25, y: 7.5))
    ctx.addQuadCurve(to: CGPoint(x: 7.75, y: 9), control: CGPoint(x: 7.75, y: 7.5))
    ctx.addLine(to: CGPoint(x: 7.75, y: 16.5))
    ctx.addQuadCurve(to: CGPoint(x: 9.25, y: 18), control: CGPoint(x: 7.75, y: 18))
    ctx.addLine(to: CGPoint(x: 13.25, y: 18))
    ctx.addLine(to: CGPoint(x: 16.75, y: 14.5))
    ctx.addLine(to: CGPoint(x: 16.75, y: 9))
    ctx.addQuadCurve(to: CGPoint(x: 15.25, y: 7.5), control: CGPoint(x: 16.75, y: 7.5))
    ctx.closePath()
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 13.25, y: 18))
    ctx.addLine(to: CGPoint(x: 13.25, y: 15.75))
    ctx.addQuadCurve(to: CGPoint(x: 14.5, y: 14.5), control: CGPoint(x: 13.25, y: 14.5))
    ctx.addLine(to: CGPoint(x: 16.75, y: 14.5))
    ctx.strokePath()
    if paused {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in [CGFloat(10), CGFloat(13)] {
            ctx.addPath(rounded(CGRect(x: x, y: 9.75, width: 1.3, height: 3.5), radius: 0.4))
            ctx.fillPath()
        }
    } else {
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: 10, y: 12.25))
        ctx.addLine(to: CGPoint(x: 14.25, y: 12.25))
        ctx.move(to: CGPoint(x: 10, y: 10.25))
        ctx.addLine(to: CGPoint(x: 12.75, y: 10.25))
        ctx.strokePath()
    }
    ctx.endPDFPage()
    ctx.closePDF()
}

let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (pixels, name) in variants { try writePNG(master, pixels: pixels, path: "\(outDir)/\(name).png") }
let buildDirectory = URL(fileURLWithPath: outDir).deletingLastPathComponent()
writeStatusIcon(paused: false, to: buildDirectory.appendingPathComponent("StatusIcon.pdf"))
writeStatusIcon(paused: true, to: buildDirectory.appendingPathComponent("StatusIconPaused.pdf"))
print("ClipDock generated artwork packaged; folded-card template icons written")
