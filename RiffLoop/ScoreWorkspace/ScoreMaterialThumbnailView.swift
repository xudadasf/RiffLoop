import ImageIO
import PDFKit
import SwiftUI
import UIKit

/// The image is immutable after it leaves the background renderer.
struct ScoreMaterialThumbnail: @unchecked Sendable {
    let image: UIImage?
}

/// Serialize low-resolution rendering so long lists do not decode many pages at once.
actor ScoreMaterialThumbnailLoader {
    static let shared = ScoreMaterialThumbnailLoader()
    private let maxPixels = 160
    private let cache: NSCache<NSString, UIImage> = {
        let result = NSCache<NSString, UIImage>()
        result.countLimit = 48
        result.totalCostLimit = 4 * 1024 * 1024
        return result
    }()

    func load(_ url: URL) -> ScoreMaterialThumbnail {
        guard !Task.isCancelled, let key = cacheKey(for: url) else { return ScoreMaterialThumbnail(image: nil) }
        if let cached = cache.object(forKey: key) { return ScoreMaterialThumbnail(image: cached) }
        let result: ScoreMaterialThumbnail = autoreleasepool {
            if url.pathExtension.lowercased() == "pdf" {
                guard let page = PDFDocument(url: url)?.page(at: 0) else {
                    return ScoreMaterialThumbnail(image: nil)
                }
                // PDFKit renders a first-page thumbnail, without loading the whole
                // document as full-resolution images. It also handles page rotation.
                let image = page.thumbnail(of: CGSize(width: CGFloat(maxPixels), height: CGFloat(maxPixels)), for: .cropBox)
                return ScoreMaterialThumbnail(image: image)
            }
            let sourceOptions: [String: Any] = [kCGImageSourceShouldCache as String: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return ScoreMaterialThumbnail(image: nil)
            }
            let options: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: maxPixels,
                kCGImageSourceShouldCacheImmediately as String: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return ScoreMaterialThumbnail(image: nil)
            }
            return ScoreMaterialThumbnail(image: UIImage(cgImage: thumbnail))
        }
        // Do not retain or return a preview if the source was replaced while rendering.
        guard !Task.isCancelled, cacheKey(for: url) == key else { return ScoreMaterialThumbnail(image: nil) }
        if let image = result.image, let cgImage = image.cgImage {
            cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        }
        return result
    }

    private func cacheKey(for url: URL) -> NSString? {
        // URL.resourceValues may cache stale metadata on a reused URL after an
        // atomic replace or deletion. Query the filesystem by path each time.
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(url.standardizedFileURL.absoluteString)|\(size)|\(modified)|\(created)|\(device)|\(inode)" as NSString
    }
}

struct ScoreMaterialThumbnailView: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(.tertiarySystemGroupedBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(2)
            } else {
                Image(systemName: url?.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let result = await ScoreMaterialThumbnailLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            image = result.image
        }
    }
}
