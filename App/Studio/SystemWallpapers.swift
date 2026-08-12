import AppKit

/// macOS system wallpapers (`/System/Library/Desktop Pictures/*.heic`) — the same imagery the
/// reference editor bundles as backgrounds, already present on every Mac. No assets shipped.
enum SystemWallpapers {
    static let directory = URL(fileURLWithPath: "/System/Library/Desktop Pictures")

    /// Names shown in the panel's grid, in display order; ones missing on this OS are skipped.
    private static let curatedNames = [
        "Sequoia", "Sonoma", "Ventura Graphic", "Monterey Graphic",
        "Big Sur Graphic Light", "Big Sur", "Radial Sky Blue",
        "iMac Blue", "iMac Purple", "iMac Orange",
    ]

    static var curated: [URL] {
        curatedNames.compactMap { name in
            let url = directory.appendingPathComponent("\(name).heic")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func all() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "heic" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Small decode via CGImageSource so a grid of 6K wallpapers stays cheap.
    static func thumbnail(_ url: URL, height: CGFloat = 44) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(height * 4),
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg,
                       size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }
}
