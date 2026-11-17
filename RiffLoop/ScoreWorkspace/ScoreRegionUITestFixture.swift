#if DEBUG
import SwiftUI
import UIKit

/// Isolated synthetic material, reachable only in Debug UI-test launches.
struct ScoreRegionUITestFixture: View {
    let id: UUID
    @StateObject private var externalOpen = ScoreExternalOpenCoordinator()
    @State private var source: URL?
    @State private var store: ScoreRegionsStore?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            if let source, let store {
                ScoreRegionEditorView(source: source, store: store)
            } else if let error { Text(error) }
            else { ProgressView("Preparing synthetic score") }
        }
        .environmentObject(externalOpen)
        .task {
            do {
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("RegionUITests/\(id.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let file = root.appendingPathComponent("synthetic-\(id.uuidString).png")
                // Use the same isolated source identity through the actual recognition path.
                let regionStore = ScoreRegionsStore(source: file)
                if !FileManager.default.fileExists(atPath: file.path) {
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
                        UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
                        UIColor.black.setStroke()
                        for y in [140, 460] {
                            for line in 0..<6 {
                                context.cgContext.move(to: CGPoint(x: 100, y: y + line * 12))
                                context.cgContext.addLine(to: CGPoint(x: 1100, y: y + line * 12))
                            }
                        }
                        context.cgContext.strokePath()
                    }
                    try image.pngData()!.write(to: file)
                    try await regionStore.savePage(index: 0, rotation: 0, regions: [
                        ScoreRegion(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, x: 0.1, y: 0.15, width: 0.3, height: 0.18),
                        ScoreRegion(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, x: 0.55, y: 0.55, width: 0.3, height: 0.18)
                    ])
                }
                store = regionStore; source = file
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
