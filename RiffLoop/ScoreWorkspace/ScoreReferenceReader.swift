import UIKit

/// Keep at most one upright page while this editor is visible; switching frames never writes an image to disk.
actor ScoreReferenceReader {
    private struct MaterialRevision: Equatable {
        let url: URL
        let generation: UUID
        let size: Int?
        let modified: Date?
    }

    private var validatedMaterial: (revision: MaterialRevision, store: ScoreRegionsStore)?
    private var cachedPage: (name: String, digest: String, index: Int, image: CGImage)?

    func image(for source: GuitarSource) async throws -> (image: String, label: String) {
        guard source.isValid else { throw ScoreRegionsError.invalidPage }
        let files = try await ScoreWorkspaceStore().files()
        guard let url = files.first(where: { $0.lastPathComponent == source.name }) else { throw ScoreRegionsError.sourceChanged }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let generation = ScoreMaterialAccess.synchronized { ScoreMaterialAccess.current(url) }
        let revision = MaterialRevision(url: url, generation: generation, size: values.fileSize, modified: values.contentModificationDate)
        let store: ScoreRegionsStore
        if let cached = validatedMaterial, cached.revision == revision {
            store = cached.store
        } else {
            store = ScoreRegionsStore(source: url)
            validatedMaterial = (revision, store)
            cachedPage = nil
        }
        let snapshot = try await store.snapshot()
        guard snapshot.sourceDigest == source.digest else { throw ScoreRegionsError.sourceChanged }
        try Task.checkCancellation()
        let image: CGImage
        if let page = cachedPage, page.name == source.name, page.digest == source.digest, page.index == source.page {
            image = page.image
        } else {
            let preview = ScorePageRenderer.render(source: url, index: source.page)
            guard let rendered = preview.image?.cgImage else { throw ScoreRegionsError.unreadableSource }
            try Task.checkCancellation()
            cachedPage = (source.name, source.digest, source.page, rendered)
            image = rendered
        }
        let reference = ScoreReferenceCrop.includingStaff(source, in: image)
        let rect = ScoreReferenceCrop.rect(for: reference, in: image)
        guard let cropped = image.cropping(to: rect.integral) else { throw ScoreRegionsError.invalidPage }
        try Task.checkCancellation()
        guard let jpeg = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.86) else { throw ScoreRegionsError.unreadableSource }
        let index = snapshot.layout.firstIndex { $0.location.pageIndex == source.page && $0.location.regionID == source.region.id }
        let label = "第 \(source.page + 1) 页" + (index.map { " · 识别框 \($0 + 1)" } ?? "")
        return (jpeg.base64EncodedString(), label)
    }
}
