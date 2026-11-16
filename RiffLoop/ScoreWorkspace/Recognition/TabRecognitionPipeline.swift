import Foundation
import UIKit

struct TabRecognitionRegion: Sendable {
    let url: URL
    let source: GuitarSource
    let rotation: Int
    let gapAfter: Int
}

actor TabRecognitionPipeline {
    static let shared = TabRecognitionPipeline()
    private var running = false

    static func regions(plan: ScoreSequencePlan, materialURLs: [String: URL]) async throws -> [TabRecognitionRegion] {
        var available = Set<ScoreSequenceRegionReference>(), resolved: [ScoreSequenceRegionReference: ScoreRegion] = [:]
        for material in plan.materials {
            guard let url = materialURLs[material.name] else { throw ScoreRegionsError.unreadableSource }
            let snapshot = try await ScoreRegionsStore(source: url).snapshot()
            guard snapshot.sourceDigest == material.sourceDigest else { throw ScoreRegionsError.sourceChanged }
            for page in snapshot.pages { for region in page.regions {
                let ref = ScoreSequenceRegionReference(material: material, pageIndex: page.index, rotation: page.rotation, regionID: region.id)
                available.insert(ref); resolved[ref] = region
            } }
        }
        let order = try plan.recognitionOrder(available: available)
        return try order.regions.enumerated().map { index, ref in
            guard let region = resolved[ref], let url = materialURLs[ref.material.name] else { throw ScoreRegionsError.sourceChanged }
            return TabRecognitionRegion(url: url, source: GuitarSource(name: ref.material.name, digest: ref.material.sourceDigest, page: ref.pageIndex, region: region),
                                        rotation: ref.rotation, gapAfter: index < order.gaps.count ? order.gaps[index] : 0)
        }
    }

    func recognize(regions: [TabRecognitionRegion], settings: ScoreRecognitionSettings,
                   progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> GuitarDraft {
        guard !running else { throw ScoreDraftExportError.busy }
        guard settings.isValid, !regions.isEmpty, regions.count <= 128 else { throw TabRecognitionError.tooLarge }
        running = true
        defer { running = false }
        var draft = GuitarDraft(title: "识别草稿", tempo: settings.tempo, numerator: settings.numerator,
                                denominator: settings.denominator, tuning: settings.tuning, bars: [])
        // A failed model still yields editable regions; missing/corrupt sources are never omitted.
        let model = Result { try TabDigitRecognizer() }
        for (index, input) in regions.enumerated() {
            await progress(index + 1, regions.count)
            do {
                try Task.checkCancellation()
                let snapshot = try await ScoreRegionsStore(source: input.url).snapshot()
                guard snapshot.sourceDigest == input.source.digest,
                      snapshot.pages.contains(where: { $0.index == input.source.page && $0.rotation == input.rotation && $0.regions.contains(input.source.region) }) else { throw ScoreRegionsError.sourceChanged }
                let bars = try autoreleasepool { () throws -> [GuitarBar] in
                    let preview = ScorePageRenderer.render(source: input.url, index: input.source.page, maximumPixelSize: 4096)
                    guard preview.orientation == input.rotation, let image = preview.image?.cgImage else { throw TabRecognitionError.invalidImage }
                    let r = input.source.region
                    guard let crop = image.cropping(to: CGRect(x: r.x * Double(image.width), y: r.y * Double(image.height), width: r.width * Double(image.width), height: r.height * Double(image.height))) else { throw TabRecognitionError.invalidImage }
                    let raster = try TabRaster(image: crop).deskewed()
                    return try transcribe(raster, model: model.get(), settings: settings, source: input.source)
                }
                draft.bars.append(contentsOf: bars)
            } catch {
                draft.bars.append(GuitarDraft.placeholder(settings: settings, source: input.source,
                    reason: error is CancellationError ? "已停止识别，此区域待手动填写" : "此区域待手动填写：\(error.localizedDescription)"))
            }
            for _ in 0..<input.gapAfter { draft.bars.append(GuitarDraft.placeholder(settings: settings, source: nil, reason: "按区域计划插入的空白小节")) }
            guard draft.bars.count <= 512 else { throw TabRecognitionError.tooLarge }
        }
        guard draft.isValidForStorage else { throw GuitarDraftStoreError.invalidDraft }
        return draft
    }

    func transcribe(_ raster: TabRaster, model: TabDigitRecognizer, settings: ScoreRecognitionSettings, source: GuitarSource?) throws -> [GuitarBar] {
        let systems = raster.systems()
        guard !systems.isEmpty else { throw TabRecognitionError.noStrings }
        var bars: [GuitarBar] = []
        for system in systems {
            for pair in zip(system.boundaries, system.boundaries.dropFirst()) {
                try Task.checkCancellation()
                var candidates: [(x: Double, note: GuitarNote)] = []
                var problems = ["数字、弦位及技巧请对照原图核对"]
                for (stringIndex, row) in system.rows.enumerated() {
                    let left = pair.0 + max(2,Int(system.gap*0.18)), right = pair.1 - 1
                    guard let band = raster.band(left: left, right: right, center: row, gap: system.gap) else { continue }
                    do {
                        var digits = try model.recognize(band.pixels, width: band.width, height: band.height, gap: system.gap)
                        // A small vertical retry is confined to this string's band.
                        if digits.isEmpty || digits.contains(where: { $0.score < 0.65 }) {
                            for shift in [-1,1] {
                                guard let retry = raster.band(left: left, right: right, center: row + Int(Double(shift)*system.gap*0.13), gap: system.gap*0.85) else { continue }
                                let other = try model.recognize(retry.pixels, width: retry.width, height: retry.height, gap: system.gap)
                                let oldScore = digits.map(\.score).reduce(0,+) / Float(max(1,digits.count))
                                let newScore = other.map(\.score).reduce(0,+) / Float(max(1,other.count))
                                if !other.isEmpty && newScore > oldScore+0.1 && (digits.isEmpty || other.count == digits.count) { digits = other }
                            }
                        }
                        if digits.isEmpty { problems.append("第 \(stringIndex+1) 弦有图形但未读出数字，请补录") }
                        for value in digits {
                            let warnings = value.fret == nil ? ["数字 \(value.text) 未确定"] : value.score < 0.8 ? ["数字较模糊，请核对"] : []
                            candidates.append((Double(left)+value.x, GuitarNote(string: stringIndex+1, fret: value.fret, review: warnings)))
                        }
                    } catch {
                        problems.append("第 \(stringIndex+1) 弦未读出，请手动补录")
                    }
                }
                candidates.sort { $0.x < $1.x }
                var groups: [(x: Double, notes: [GuitarNote])] = []
                for item in candidates {
                    if let last = groups.last, abs(item.x-last.x) <= system.gap*0.65, !last.notes.contains(where: { $0.string == item.note.string }) {
                        groups[groups.count-1].notes.append(item.note)
                    } else { groups.append((item.x,[item.note])) }
                }
                if groups.isEmpty { bars.append(GuitarDraft.placeholder(settings: settings, source: source, reason: problems.joined(separator: "；"))); continue }
                // Never drop recognized notes to fit a guessed measure count.
                // A pathological large group is split explicitly and flagged.
                for start in stride(from: 0, to: groups.count, by: 128) {
                    let portion = Array(groups[start..<min(groups.count,start+128)])
                    var duration = settings.denominator, tuplet = 1
                    let expected = Double(settings.numerator)*3840/Double(settings.denominator)
                    while Double(portion.count)*3840/Double(duration) > expected && duration < 64 { duration *= 2 }
                    while Double(portion.count)*3840/Double(duration*tuplet) > expected && tuplet < 16 { tuplet *= 2 }
                    var beats = portion.map { GuitarBeat(duration: duration, tupletNumerator: tuplet, notes: $0.notes, review: ["时值为默认值，请核对"]) }
                    var remaining = expected-beats.reduce(0) { $0+$1.ticks }
                    for restDuration in [1,2,4,8,16,32,64] {
                        while remaining >= 3840/Double(restDuration)-0.01 && remaining > 0.01 && beats.count < 128 {
                            beats.append(GuitarBeat(duration: restDuration, review: ["默认补齐的休止，请核对位置"]))
                            remaining -= 3840/Double(restDuration)
                        }
                    }
                    var reviews = problems + ["时值暂用默认；请核对开头休止和连音"]
                    if groups.count > 128 { reviews.append("候选过多，已临时拆节，需重新核对小节边界") }
                    bars.append(GuitarBar(beats: beats, review: reviews, source: source))
                }
            }
        }
        return bars
    }
}
