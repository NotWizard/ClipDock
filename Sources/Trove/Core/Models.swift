import AppKit
import Foundation

// MARK: - Item kinds

enum ItemKind: Int, Codable, CaseIterable, Identifiable, Hashable {
    case text = 0
    case link = 1
    case image = 2
    case color = 3
    case files = 4
    case unknown = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .text: return "文本"
        case .link: return "链接"
        case .image: return "图片"
        case .color: return "颜色"
        case .files: return "文件"
        case .unknown: return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .files: return "doc.on.doc"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    /// Accent used for the card chrome.
    var accent: NSColor {
        switch self {
        case .text: return NSColor(srgbRed: 0.30, green: 0.45, blue: 0.78, alpha: 1)
        case .link: return NSColor(srgbRed: 0.16, green: 0.60, blue: 0.56, alpha: 1)
        case .image: return NSColor(srgbRed: 0.72, green: 0.42, blue: 0.70, alpha: 1)
        case .color: return NSColor(srgbRed: 0.85, green: 0.60, blue: 0.20, alpha: 1)
        case .files: return NSColor(srgbRed: 0.42, green: 0.52, blue: 0.62, alpha: 1)
        case .unknown: return NSColor.secondaryLabelColor
        }
    }
}

/// One stored pasteboard flavour. Bytes live in a sidecar file so that pasting
/// can reproduce the original item faithfully (rich text, html, tiff, pdf, …).
struct PayloadFile: Codable, Hashable {
    var type: String
    var filename: String
    /// Index of the originating pasteboard item. One pasteboard entry can carry
    /// several items (multi-file copies); the index preserves that grouping so
    /// writing back does not collapse them into a single item.
    var itemIndex: Int? = 0
}

// MARK: - Clip item

struct ClipItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: ItemKind = .text
    var createdAt: Date = Date()
    var pinned: Bool = false
    var pinboardID: UUID?
    /// Manual order inside a pinboard (drag & drop). Lower is earlier.
    var displayOrder: Int = 0

    var sourceBundleID: String?
    var sourceName: String?

    /// Short single-line label shown in lists and cards.
    var title: String = ""
    /// Lowercased blob used by search (body text, OCR output, link title…).
    var searchText: String = ""

    var text: String?
    var urlString: String?
    var colorHex: String?
    var colorComponents: [Double]?
    var filePaths: [String] = []
    var imageName: String?
    var imagePixelSize: [Int]?

    var checksum: String = ""
    var payloads: [PayloadFile] = []

    // MARK: Derived

    var host: String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return url.host?.replacingOccurrences(of: "www.", with: "")
    }

    var imageURL: URL? {
        guard let imageName else { return nil }
        return Store.itemsDirectory.appendingPathComponent(imageName)
    }
}

// MARK: - Pinboard

struct Pinboard: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String = Pinboard.palette[0]
    var createdAt: Date = Date()

    static let palette: [String] = [
        "C8A15A", // brass
        "4C8BF5", // blue
        "34A853", // green
        "E8710A", // orange
        "C5221F", // red
        "8E5BD8", // violet
        "1FA2A6", // teal
        "D6457A", // pink
    ]

    var color: NSColor { NSColor(hex: colorHex) ?? .systemBlue }
}

// MARK: - Source application

struct SourceApp {
    var bundleID: String?
    var name: String?
    var icon: NSImage?
    var color: NSColor

    static let unknown = SourceApp(bundleID: nil, name: nil, icon: nil, color: .secondaryLabelColor)
}

// MARK: - Colour helpers

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                      green: CGFloat((v >> 8) & 0xFF) / 255,
                      blue: CGFloat(v & 0xFF) / 255,
                      alpha: 1)
        } else {
            self.init(srgbRed: CGFloat((v >> 24) & 0xFF) / 255,
                      green: CGFloat((v >> 16) & 0xFF) / 255,
                      blue: CGFloat((v >> 8) & 0xFF) / 255,
                      alpha: CGFloat(v & 0xFF) / 255)
        }
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "888888" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
