import AppKit
import SwiftUI
import QuickLookThumbnailing

struct StoreNotice: View {
    @ObservedObject var store: Store
    var body: some View {
        if let notice = store.notice {
            VStack(alignment: .leading, spacing: 10) {
                Label(notice, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("打开资料库位置") { NSWorkspace.shared.open(Store.root) }
                    Spacer()
                    if store.isReadOnly { Button("重新读取") { store.reload() } }
                    else { Button("关闭提示") { store.dismissNotice() } }
                }
                .font(.system(size: 12))
            }
            .padding(14).frame(maxWidth: 560)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }
}

enum Theme {
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.14)
    static let cardRadius: CGFloat = 16
    static let sidebarWidth: CGFloat = 232
    static let cardBackground = Color(nsColor: .textBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let contentBackground = Color(nsColor: .underPageBackgroundColor)
    static let hairline = Color.primary.opacity(0.12)
}

enum TroveBrand {
    static func appIcon() -> NSImage {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) ?? statusIcon()
    }
    static func statusIcon(paused: Bool = false) -> NSImage {
        let name = paused ? "StatusIconPaused" : "StatusIcon"
        let image = Bundle.main.url(forResource: name, withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: paused ? "pause.rectangle" : "tray.and.arrow.down", accessibilityDescription: AppIdentity.name)!
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        return image
    }
}

@MainActor
enum SourceAppearance {
    private static var cache: [String: (NSImage?, NSColor)] = [:]

    static func appearance(for item: ClipItem) -> (icon: NSImage?, color: NSColor) {
        guard let bundleID = item.sourceBundleID else { return (nil, readableHeader(item.kind.accent)) }
        if let result = cache[bundleID] { return result }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (nil, readableHeader(item.kind.accent))
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let result = (Optional(icon), readableHeader(dominantColor(in: icon) ?? item.kind.accent))
        cache[bundleID] = result
        return result
    }

    static func readableHeader(_ color: NSColor) -> NSColor {
        let source = color.usingColorSpace(.sRGB) ?? .systemBlue
        let scale = 0.98 / max(source.brightnessComponent, 0.001)
        // Scale RGB together to preserve the icon's hue and saturation in sRGB.
        let tint = source.saturationComponent < 0.12
            ? NSColor(srgbRed: 0.72, green: 0.72, blue: 0.72, alpha: 1)
            : NSColor(srgbRed: source.redComponent * scale, green: source.greenComponent * scale,
                      blue: source.blueComponent * scale, alpha: 1)
        return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).blended(
            withFraction: 0.44, of: tint
        )!.usingColorSpace(.sRGB)!
    }

    static let headerInk = NSColor(srgbRed: 0.07, green: 0.12, blue: 0.20, alpha: 1)

    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? .black
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    static func dominantColor(in image: NSImage) -> NSColor? {
        let size = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        var buckets = [(weight: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0, 0), count: 24)
        var opaqueArea: CGFloat = 0
        var coloredArea: CGFloat = 0
        for y in 0..<size {
            for x in 0..<size {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.5 else { continue }
                opaqueArea += c.alphaComponent
                guard c.saturationComponent > 0.2, c.brightnessComponent > 0.18 else { continue }
                coloredArea += c.alphaComponent
                let i = min(buckets.count - 1, Int(c.hueComponent * CGFloat(buckets.count)))
                // Area leads; saturation only modestly favors a clear color over a muted one.
                let weight = c.alphaComponent * (0.5 + 0.5 * c.saturationComponent)
                buckets[i].weight += weight
                buckets[i].r += c.redComponent * weight
                buckets[i].g += c.greenComponent * weight
                buckets[i].b += c.blueComponent * weight
            }
        }
        guard opaqueArea > 0 else { return nil }
        // A few antialiased pixels or a tiny colored badge must not tint a monochrome icon.
        guard coloredArea / opaqueArea >= 0.03 else { return NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1) }
        // Merge neighboring hues, including red across 0°/360°, without averaging unrelated colors.
        let groups = buckets.indices.map { i -> (weight: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat) in
            let previous = buckets[(i + buckets.count - 1) % buckets.count]
            let current = buckets[i]
            let next = buckets[(i + 1) % buckets.count]
            return (current.weight + 0.5 * (previous.weight + next.weight),
                    current.r + 0.5 * (previous.r + next.r),
                    current.g + 0.5 * (previous.g + next.g),
                    current.b + 0.5 * (previous.b + next.b))
        }
        guard let group = groups.max(by: { $0.weight < $1.weight }), group.weight > 0 else { return nil }
        return NSColor(srgbRed: group.r / group.weight, green: group.g / group.weight,
                       blue: group.b / group.weight, alpha: 1)
    }
}

struct KindBadge: View {
    let kind: ItemKind
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Color(nsColor: kind.accent))
            .frame(width: size, height: size)
            .background(Color(nsColor: kind.accent).opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3))
    }
}

struct SourceBadge: View {
    let item: ClipItem
    var size: CGFloat = 16
    var body: some View {
        if let icon = SourceAppearance.appearance(for: item).icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.7)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

struct Chip: View {
    let text: String
    var selected = false
    var tint: Color = Theme.accent
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? tint.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? tint : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

enum Format {
    static func relative(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600))小时前" }
        if seconds < 604800 { return "\(Int(seconds / 86400))天前" }
        return date.formatted(.dateTime.month().day())
    }
    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct TransparencyGrid: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            let base: Double = scheme == .dark ? 0.13 : 0.91
            for y in 0...Int(size.height / 8) {
                for x in 0...Int(size.width / 8) {
                    let color = Color(white: base + ((x + y).isMultiple(of: 2) ? 0 : 0.045))
                    context.fill(Path(CGRect(x: x * 8, y: y * 8, width: 8, height: 8)), with: .color(color))
                }
            }
        }
    }
}

struct FileThumbnail: View {
    let path: String
    var size: CGFloat = 32
    @LocalState private var thumbnail: NSImage?
    private static let cache = NSCache<NSURL, NSImage>()
    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: path))
            .resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
            .task {
                let url = URL(fileURLWithPath: path)
                if let cached = Self.cache.object(forKey: url as NSURL) { thumbnail = cached; return }
                guard FileManager.default.fileExists(atPath: path) else { return }
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128),
                                                           scale: 2, representationTypes: .thumbnail)
                guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
                let image = representation.nsImage
                Self.cache.setObject(image, forKey: url as NSURL)
                thumbnail = image
            }
    }
}

struct ItemPreviewContent: View {
    let item: ClipItem
    var compact = false
    var body: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? item.title)
                .font(.system(size: compact ? 12 : 13))
                .lineSpacing(2).lineLimit(compact ? 4 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .link:
            VStack(alignment: .leading, spacing: 7) {
                if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: compact ? 50 : 88)
                } else {
                    Image(systemName: "globe").font(.system(size: compact ? 24 : 34, weight: .light))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image:
            ZStack {
                TransparencyGrid()
                if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .color:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: NSColor(hex: item.colorHex ?? "888888") ?? .gray))
                .overlay(alignment: .bottomLeading) {
                    Text("#\(item.colorHex ?? "")").font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8)
                }
        case .files:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(item.filePaths.prefix(3)), id: \.self) { path in
                    HStack(spacing: 9) {
                        FileThumbnail(path: path)
                        Text((path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                    }
                }
                if item.filePaths.count > 3 {
                    Text("另有 \(item.filePaths.count - 3) 个文件").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .unknown:
            VStack(spacing: 10) {
                Image(systemName: "doc.questionmark").font(.system(size: 30, weight: .light))
                Text(item.title).font(.system(size: 12)).lineLimit(3)
            }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ItemCard: View {
    let item: ClipItem
    let isSelected: Bool
    var showSource = true
    @LocalState private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.kind.title).font(.system(size: 14, weight: .semibold))
                    Text(Format.relative(item.createdAt)).font(.system(size: 11))
                }
                .padding(.leading, 12)
                Spacer(minLength: 0)
                if item.pinned { Image(systemName: "pin.fill").font(.system(size: 11)) }
                if showSource { SourceBadge(item: item, size: 48) }
            }
            .frame(height: 48).foregroundStyle(Color(nsColor: SourceAppearance.headerInk))
            .background(Color(nsColor: SourceAppearance.appearance(for: item).color))

            ItemPreviewContent(item: item)
                .padding(item.kind == .image ? 0 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text(summary).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.72)).lineLimit(1)
                .frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 3)
        }
        .frame(width: 232, height: 232)
        .background(Theme.cardBackground)
        .overlay(hovering ? Color.primary.opacity(0.025) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .shadow(color: .black.opacity(isSelected ? 0.18 : 0.08), radius: isSelected ? 8 : 4, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.title)，\(item.title)，\(item.sourceName ?? "未知来源")")
        .accessibilityValue(isSelected ? "已选择" : "")
    }

    private var summary: String {
        switch item.kind {
        case .text: return "\(item.text?.count ?? 0) 个字符"
        case .image:
            if let size = item.imagePixelSize, size.count >= 2 { return "\(size[0]) × \(size[1])" }
            return "图片"
        case .files: return "\(item.filePaths.count) 个文件"
        case .color: return "#\(item.colorHex ?? "")"
        case .link: return item.host ?? "链接"
        case .unknown: return item.sourceName ?? "其他内容"
        }
    }
}
