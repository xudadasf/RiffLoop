import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Photos picker owns its supplied URL only during the import closure.
/// Copy it to a temporary file there, so the workspace can import it later.
struct ScorePhotoImport: Transferable {
    let temporaryURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try copyForImport(from: received.file)
        }
    }

    static func copyForImport(from source: URL, temporaryFolder: URL = FileManager.default.temporaryDirectory) throws -> ScorePhotoImport {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(identifier) else {
            throw ScorePhotoImportError.unsupportedImage
        }

        let formats = [("jpg", "jpeg"), ("png", "png"), ("heic", "heic"), ("heif", "heif"), ("tiff", "tiff")]
        guard let ext = formats.first(where: { format in
            guard let supported = UTType(filenameExtension: format.1) else { return false }
            return type.conforms(to: supported)
        })?.0 else {
            throw ScorePhotoImportError.unsupportedImage
        }
        let destination = temporaryFolder.appendingPathComponent("相册照片-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return ScorePhotoImport(temporaryURL: destination)
    }
}

enum ScorePhotoImportError: LocalizedError {
    case unavailable
    case unsupportedImage

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法读取照片，请检查照片是否已从 iCloud 下载。"
        case .unsupportedImage: "此照片格式暂不支持，请使用 JPEG、PNG、HEIC 或 TIFF 图片。"
        }
    }
}
