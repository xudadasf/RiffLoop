import CoreGraphics
import Foundation

struct TabSystem: Equatable {
    var rows: [Int]
    var left: Int
    var right: Int
    var boundaries: [Int]
    var gap: Double { Double(rows[5] - rows[0]) / 5 }
}

struct TabRaster {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096, pixels.count == width * height else { throw TabRecognitionError.invalidImage }
        self.width = width; self.height = height; self.pixels = pixels
    }
    init(image: CGImage) throws {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 4096, h <= 4096 else { throw TabRecognitionError.tooLarge }
        var bytes = [UInt8](repeating: 255, count: w * h)
        let success = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard success else { throw TabRecognitionError.invalidImage }
        let samples = stride(from: 0, to: bytes.count, by: max(1, bytes.count / 2000)).map { bytes[$0] }.sorted()
        if samples[samples.count / 2] < 100 { bytes = bytes.map { 255 - $0 } }
        try self.init(width: w, height: h, pixels: bytes)
    }

    /// Local mean threshold handles uneven illumination without inventing glyphs.
    func mask() -> [UInt8] {
        let stride = width + 1
        var integral = [Int](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var sum = 0
            for x in 0..<width { sum += Int(pixels[y * width + x]); integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + sum }
        }
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let t = max(0, y - 20), b = min(height, y + 21)
            for x in 0..<width {
                let l = max(0, x - 20), r = min(width, x + 21)
                let sum = integral[b * stride + r] - integral[t * stride + r] - integral[b * stride + l] + integral[t * stride + l]
                if Int(pixels[y * width + x]) < sum / ((b-t)*(r-l)) - 12 { result[y * width + x] = 1 }
            }
        }
        return result
    }

    /// Projection sharpness estimates staff slope. Only a small rigid correction;
    /// perspective/curved pages remain marked for review rather than guessed.
    func deskewed() throws -> TabRaster {
        let mask = mask(), sampleStep = max(2, width / 600)
        var points: [(Int, Int)] = []
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: sampleStep) where mask[y * width + x] == 1 { points.append((x,y)) }
        }
        guard points.count > 100 else { return self }
        func score(_ angle: Double) -> Double {
            let slope = tan(angle * .pi / 180), padding = width / 5 + 2
            var bins = [Int](repeating: 0, count: height + padding * 2)
            for (x,y) in points { let row = Int((Double(y)-slope*Double(x-width/2)).rounded()) + padding; if bins.indices.contains(row) { bins[row] += 1 } }
            return bins.reduce(0) { $0 + Double($1 * $1) }
        }
        let baseline = score(0)
        var best = 0.0, bestScore = baseline
        for step in -32...32 { let angle = Double(step)/4; let value = score(angle); if value > bestScore { best = angle; bestScore = value } }
        guard abs(best) >= 0.2, bestScore > baseline * 1.12 else { return self }
        // Shear keeps every source row/column; no crop at the page edges.
        let slope = tan(best * .pi / 180), padding = Int(ceil(abs(slope) * Double(width) / 2)) + 2
        let h = height + padding * 2
        guard h <= 4096 else { return self }
        var out = [UInt8](repeating: 255, count: width * h)
        for y in 0..<h { for x in 0..<width {
            let source = Double(y-padding) + slope * Double(x-width/2), lo = Int(floor(source)), fraction = source - floor(source)
            if lo >= 0 && lo+1 < height { out[y*width+x] = UInt8((Double(pixels[lo*width+x])*(1-fraction)+Double(pixels[(lo+1)*width+x])*fraction).rounded()) }
        } }
        return try TabRaster(width: width, height: h, pixels: out)
    }

    static func groups(_ indices: [Int]) -> [[Int]] {
        var groups: [[Int]] = []
        for i in indices { if let last = groups.last?.last, i == last+1 { groups[groups.count-1].append(i) } else { groups.append([i]) } }
        return groups
    }

    func systems() -> [TabSystem] {
        let ink = mask(), runLength = max(12, width / 60)
        var horizontal = [UInt8](repeating: 0, count: ink.count), coverage = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var start = 0
            for x in 0...width {
                if x < width && ink[y*width+x] == 1 { continue }
                if x-start >= runLength { for a in start..<x { horizontal[y*width+a] = 1 }; coverage[y] += x-start }
                start = x+1
            }
        }
        let rows = Self.groups((0..<height).filter { coverage[$0] > max(40, width / 6) }).map { group in
            let peak = group.map { coverage[$0] }.max() ?? 0
            let best = group.filter { coverage[$0] == peak }
            return best.reduce(0,+) / best.count
        }
        guard rows.count >= 6 else { return [] }
        var result: [TabSystem] = [], used = Set<Int>()
        for start in 0...(rows.count-6) {
            let ys = Array(rows[start..<start+6]), gap = Double(ys[5]-ys[0])/5
            guard gap >= 4, gap <= 90, !ys.contains(where: used.contains),
                  zip(ys,ys.dropFirst()).allSatisfy({ abs(Double($0.1-$0.0)-gap) <= max(2,gap*0.18) }) else { continue }
            var support = [Int](repeating: 0, count: width)
            for y in ys { for x in 0..<width { if (max(0,y-1)...min(height-1,y+1)).contains(where: { horizontal[$0*width+x] == 1 }) { support[x] += 1 } } }
            let xs = (0..<width).filter { support[$0] >= 4 }
            guard let left = xs.first, let right = xs.last, right-left >= max(70,Int(gap*8)),
                  ys.allSatisfy({ y in (left...right).filter { horizontal[y*width+$0] == 1 }.count > (right-left)/2 }) else { continue }
            let neighbors = rows.filter { abs(Double($0-ys[0])+gap)<gap*0.18 || abs(Double($0-ys[5])-gap)<gap*0.18 }
            if neighbors.contains(where: { y in (left...right).filter { horizontal[y*width+$0] == 1 }.count > (right-left)/2 }) { continue }
            if Self.groups((left...right).filter { support[$0] < 2 }).contains(where: { Double($0.count)>gap*6 }) { continue }
            let vertical = (left...right).filter { x in
                let count = (ys[0]...ys[5]).reduce(0) { $0 + Int(ink[$1*width+x]) }
                return Double(count) > Double(ys[5]-ys[0]+1)*0.88
            }
            let candidates = Self.groups(vertical).map { $0.reduce(0,+)/$0.count }.filter { x in
                guard Double(x-left)>gap*1.5, Double(right-x)>gap*0.8 else { return false }
                let bottom = min(height-1,ys[5]+Int(gap*1.7)), top = min(bottom,ys[5]+max(1,Int(gap*0.3)))
                let below = (top...bottom).filter { y in (max(0,x-1)...min(width-1,x+1)).contains { ink[y*width+$0] == 1 } }.count
                return Double(below) < Double(bottom-top+1)*0.45
            }
            var boundaries = [left]
            for x in candidates { if Double(x-(boundaries.last ?? left)) > gap*0.8 { boundaries.append(x) } }
            boundaries.append(right)
            result.append(TabSystem(rows: ys, left: left, right: right, boundaries: boundaries)); used.formUnion(ys)
        }
        return result
    }

    func band(left: Int, right: Int, center: Int, gap: Double) -> (pixels: [UInt8], width: Int, height: Int)? {
        let l = max(0,left), r = min(width,right), top = max(0,Int((Double(center)-gap*0.45).rounded())), bottom = min(height,Int((Double(center)+gap*0.45).rounded())+1)
        guard r>l, bottom>top else { return nil }
        let pixels = (top..<bottom).flatMap { Array(self.pixels[($0*width+l)..<($0*width+r)]) }
        // Reject empty strings: line ink alone is not a note. Require ink away from the centre.
        let margin = max(2,Int(gap*0.16)), ink = pixels.enumerated().filter { index,value in abs(index/(r-l)-(center-top))>margin && value < 155 }.count
        guard ink >= max(4,Int(gap*0.6)) else { return nil }
        return (pixels,r-l,bottom-top)
    }
}
