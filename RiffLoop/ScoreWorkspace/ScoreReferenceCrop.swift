import CoreGraphics
import Foundation

enum ScoreReferenceCrop {
    static func rect(for source: GuitarSource, in image: CGImage) -> CGRect {
        let r = source.region
        let top = source.referenceTop ?? r.y
        return CGRect(x: r.x * Double(image.width), y: top * Double(image.height),
                      width: r.width * Double(image.width), height: (r.y + r.height - top) * Double(image.height))
    }

    /// Extend a TAB box only when the immediately preceding staff has five lines.
    /// The original six-line box remains the input to fret recognition.
    static func includingStaff(_ source: GuitarSource, in image: CGImage) -> GuitarSource {
        guard source.referenceTop == nil, source.region.isValid else { return source }
        let box = rect(for: source, in: image)
        guard box.minY > 0, box.width >= 40 else { return source }
        let top = max(0, floor(box.minY - min(box.width * 0.55, box.height * 4)))
        let search = CGRect(x: box.minX, y: top, width: box.width, height: box.maxY - top).integral
        guard let band = image.cropping(to: search) else { return source }
        let scale = min(1, 900 / Double(band.width), 650 / Double(band.height))
        let width = max(1, Int(Double(band.width) * scale)), height = max(1, Int(Double(band.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(bounds)
            ctx.interpolationQuality = .medium
            ctx.draw(band, in: bounds)
            return true
        }
        guard drawn, height >= 20 else { return source }
        let sy = Double(height) / Double(band.height)
        let boxStart = (box.minY - search.minY) * sy
        // Sample the same x positions at each slope. A candidate must match both staves.
        let columns = Array(stride(from: width / 12, to: width - width / 12, by: max(1, width / 96)))
        for slope in [0.0, -0.006, 0.006, -0.013, 0.013, -0.025, 0.025, -0.045, 0.045, -0.07, 0.07] {
            let offsets = columns.map { Int((Double($0 - width / 2) * slope).rounded()) }
            var coverage = [Int](repeating: 0, count: height)
            for (x, offset) in zip(columns, offsets) {
                for y in 2..<(height - 2) {
                    let index = y * width + x
                    let light = max(pixels[index - 2 * width], pixels[index + 2 * width])
                    let row = y - offset
                    if coverage.indices.contains(row), Int(light) - Int(pixels[index]) > 17 { coverage[row] += 1 }
                }
            }
            let rows = TabRaster.groups(coverage.indices.filter { coverage[$0] * 100 >= columns.count * 43 }).compactMap { group in
                group.max(by: { coverage[$0] < coverage[$1] })
            }
            guard let staffTop = pairedStaffTop(rows, boxStart: boxStart) else { continue }
            let above = max(0, search.minY + (staffTop - abs(slope) * Double(width) / 2) / sy) / Double(image.height)
            var result = source
            if above < source.region.y { result.referenceTop = above }
            return result
        }
        return source
    }

    static func pairedStaffTop(_ rows: [Int], boxStart: Double) -> Double? {
        guard rows.count >= 11 else { return nil }
        func spacing(_ start: Int, count: Int) -> Double? {
            let end = start + count - 1
            let gap = Double(rows[end] - rows[start]) / Double(count - 1)
            guard gap >= 2.5 else { return nil }
            let tolerance = max(1.25, gap * 0.2)
            for i in start..<end where abs(Double(rows[i + 1] - rows[i]) - gap) > tolerance { return nil }
            if start > 0, abs(Double(rows[start] - rows[start - 1]) - gap) <= tolerance { return nil }
            if end + 1 < rows.count, abs(Double(rows[end + 1] - rows[end]) - gap) <= tolerance { return nil }
            return gap
        }
        for tab in 5...(rows.count - 6) where Double(rows[tab]) >= boxStart - 2 {
            guard let tabGap = spacing(tab, count: 6) else { continue }
            let staff = tab - 5
            guard let gap = spacing(staff, count: 5), (0.45...1.9).contains(gap / tabGap),
                  Double(rows[tab] - rows[tab - 1]) <= 15 * max(gap, tabGap) else { return nil }
            let top = Double(rows[staff]) - gap * 7
            // Beams and ledger lines above this staff belong in the reference. Only
            // a complete preceding TAB system should limit the extra space for notes.
            if staff >= 6 {
                for previous in stride(from: staff - 6, through: 0, by: -1) {
                    if spacing(previous, count: 6) != nil {
                        return max(top, Double(rows[previous + 5]) + gap)
                    }
                }
            }
            return top
        }
        return nil
    }
}
