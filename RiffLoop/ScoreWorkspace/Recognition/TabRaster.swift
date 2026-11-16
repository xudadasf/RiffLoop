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
    private final class MaskCache { var value: [UInt8]? }
    private let cache = MaskCache()
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
        if let value = cache.value { return value }
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
        cache.value = result
        return result
    }

    /// Projection sharpness estimates staff slope. Only a small rigid correction;
    /// perspective/curved pages remain marked for review rather than guessed.
    func deskewed() throws -> TabRaster {
        let mask = mask(), sampleStep = max(2, width / 600)
        var points: [(Int, Int)] = []
        // Do not skip every second row: that aliases the zero-degree histogram
        // and can beat the correct angle even on visibly tilted staff lines.
        for y in 0..<height {
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
        let coarse = best
        for step in -10...10 { let angle = coarse + Double(step)/40; let value = score(angle); if value > bestScore { best = angle; bestScore = value } }
        guard abs(best) >= 0.2, bestScore > baseline * 1.12 else { return self }
        // Rotate both axes. A shear levels strings but leaves tilted bar lines,
        // causing multiple real measures to be merged into one.
        let angle = best * .pi / 180, c = cos(angle), s = sin(angle)
        let w = Int(ceil(Double(width)*c+Double(height)*abs(s)))
        let h = Int(ceil(Double(height)*c+Double(width)*abs(s)))
        guard w <= 4096, h <= 4096 else { return self }
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let dx = Double(x)-Double(w)/2, dy = Double(y)-Double(h)/2
            let sx = c*dx-s*dy+Double(width)/2, sy = s*dx+c*dy+Double(height)/2
            let ix = Int(floor(sx)), iy = Int(floor(sy)), fx = sx-floor(sx), fy = sy-floor(sy)
            if ix >= 0 && ix+1 < width && iy >= 0 && iy+1 < height {
                let top = Double(pixels[iy*width+ix])*(1-fx)+Double(pixels[iy*width+ix+1])*fx
                let bottom = Double(pixels[(iy+1)*width+ix])*(1-fx)+Double(pixels[(iy+1)*width+ix+1])*fx
                out[y*w+x] = UInt8((top*(1-fy)+bottom*fy).rounded())
            }
        } }
        return try TabRaster(width: w, height: h, pixels: out)
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
            guard gap >= 4, gap <= 180, !ys.contains(where: used.contains),
                  zip(ys,ys.dropFirst()).allSatisfy({ abs(Double($0.1-$0.0)-gap) <= max(2,gap*0.18) }) else { continue }
            var support = [Int](repeating: 0, count: width)
            for y in ys { for x in 0..<width { if (max(0,y-3)...min(height-1,y+3)).contains(where: { horizontal[$0*width+x] == 1 }) { support[x] += 1 } } }
            let xs = (0..<width).filter { support[$0] >= 4 }
            guard let left = xs.first, let right = xs.last, right-left >= max(70,Int(gap*8)) else { continue }
            var allSupported = true, strongLines = 0
            for y in ys {
                var supported = 0
                for x in left...right {
                    for localY in max(0,y-2)...min(height-1,y+2) {
                        if horizontal[localY*width+x] == 1 { supported += 1; break }
                    }
                }
                if supported <= (right-left)/4 { allSupported = false; break }
                if supported > (right-left)/2 { strongLines += 1 }
            }
            // Dense fret labels erase much of one or two strings. The remaining
            // four strong lines still establish the same six-line geometry.
            guard allSupported, strongLines >= 4 else { continue }
            let neighbors = rows.filter { abs(Double($0-ys[0])+gap)<gap*0.18 || abs(Double($0-ys[5])-gap)<gap*0.18 }
            if neighbors.contains(where: { y in (left...right).filter { horizontal[y*width+$0] == 1 }.count > (right-left)/2 }) { continue }
            if Self.groups((left...right).filter { support[$0] < 2 }).contains(where: { Double($0.count)>gap*6 }) { continue }
            // Perspective can leave barlines slightly slanted after the six
            // strings are level. Require a continuous narrow path, not one column.
            let pathRadius=max(1,Int(gap*0.12))
            var vertical:[Int]=[]
            for x in left...right {
                let l=max(0,x-pathRadius),r=min(width-1,x+pathRadius)
                func occupied(_ y:Int)->Bool {
                    for column in l...r where ink[y*width+column] == 1 { return true }
                    return false
                }
                var midpoints=0
                for pair in zip(ys,ys.dropFirst()) { if occupied((pair.0+pair.1)/2) { midpoints += 1 } }
                guard midpoints==5 else { continue }
                var count=0
                for y in ys[0]...ys[5] { if occupied(y) { count += 1 } }
                if Double(count)>Double(ys[5]-ys[0]+1)*0.88 { vertical.append(x) }
            }
            var candidates: [Int] = []
            for group in Self.groups(vertical) {
                let x = group.reduce(0,+)/group.count
                guard Double(x-left)>gap*1.5, Double(right-x)>gap*0.8 else { continue }
                let bottom = min(height-1,ys[5]+Int(gap*1.7)), top = min(bottom,ys[5]+max(1,Int(gap*0.3)))
                var below = 0
                for y in top...bottom {
                    for column in max(0,x-1)...min(width-1,x+1) {
                        if ink[y*width+column] == 1 { below += 1; break }
                    }
                }
                guard Double(below) < Double(bottom-top+1)*0.45 else { continue }
                let radius = max(2,Int((gap*0.25).rounded()))
                var centers: [Double] = []
                for pair in zip(ys,ys.dropFirst()) {
                    let y = Int((Double(pair.0+pair.1)/2).rounded())
                    var sum = 0, count = 0
                    for column in max(0,x-radius)...min(width-1,x+radius) where ink[y*width+column] == 1 { sum += column; count += 1 }
                    if count > 0 { centers.append(Double(sum)/Double(count)) }
                }
                var straightColumns = 0
                for column in max(0,x-1)...min(width-1,x+1) {
                    var count = 0
                    for y in ys[0]...ys[5] { count += Int(ink[y*width+column]) }
                    if Double(count) >= Double(ys[5]-ys[0]+1)*0.98 { straightColumns += 1 }
                }
                if centers.count == 5 {
                    var deviation=0.0
                    for i in 0..<5 { deviation=max(deviation,abs(centers[i]-(centers[0]+Double(i)*(centers[4]-centers[0])/4))) }
                    let linear=centers.max()! - centers.min()! <= gap*0.5 && deviation<=max(1.2,gap*0.08)
                    if straightColumns>=2 || linear { candidates.append(x) }
                }
            }
            var boundaries = [left]
            for x in candidates { if Double(x-(boundaries.last ?? left)) > gap*0.8 { boundaries.append(x) } }
            boundaries.append(right)
            result.append(TabSystem(rows: ys, left: left, right: right, boundaries: boundaries)); used.formUnion(ys)
        }
        return result
    }

    func localRows(_ system: TabSystem, left: Int, right: Int) -> [Int] {
        let ink = mask()
        let radius = max(2,Int(system.gap*0.25))
        return system.rows.map { row in
            let range = max(0,row-radius)...min(height-1,row+radius)
            let coverage = range.map { y in (left..<right).reduce(0) { $0 + Int(ink[y*width+$1]) } }
            let peak = coverage.max() ?? 0
            let best = zip(range,coverage).filter { $0.1 == peak }.map { $0.0 }
            return best.reduce(0,+)/max(1,best.count)
        }
    }

    /// Accept only consistent, visible beam groups. Mixed rhythms, dots, rests
    /// and tuplets are deliberately left for manual verification.
    func uniformBeamDuration(_ system: TabSystem, positions: [Double], expectedTicks: Double) -> Int? {
        guard positions.count >= 4 else { return nil }
        let ink = mask(), gap = system.gap
        let top = max(0,system.rows[0]-Int(gap*3)), bottom = min(height-1,system.rows[5]+Int(gap*3))
        var counts: [Int] = []
        for pair in zip(positions,positions.dropFirst()) {
            let distance = pair.1-pair.0
            guard distance >= gap*0.9, distance <= gap*4 else { continue }
            let l = max(0,Int(pair.0+gap*0.3)), r = min(width-1,Int(pair.1-gap*0.3))
            guard r-l >= max(4,Int(gap*0.5)) else { continue }
            let rows = (top...bottom).filter { y in
                !system.rows.contains(where: { abs($0-y)<=2 }) &&
                    Double((l...r).reduce(0) { $0+Int(ink[y*width+$1]) }) >= Double(r-l+1)*0.82
            }
            let bands = Self.groups(rows).filter { $0.count >= max(2,Int(gap*0.12)) && Double($0.count)<=gap*0.5 }
            if (1...4).contains(bands.count) { counts.append(bands.count) }
        }
        guard counts.count >= max(3,positions.count/2), Set(counts).count == 1, let count = counts.first else { return nil }
        let duration = 1 << (count+2)
        guard duration <= 64, abs(Double(positions.count)*3840/Double(duration)-expectedTicks)<0.01 else { return nil }
        return duration
    }

    func isCrossingStem(x: Double, row: Int, gap: Double) -> Bool {
        let ink = mask(), radius = max(2,Int(gap*0.25))
        let top = max(0,row-Int(gap*0.85)), bottom = min(height-1,row+Int(gap*0.85))
        let centeredRadius = max(3,Int(gap*0.4)), margin = max(2,Int(gap*0.16)), half = max(margin+1,Int(gap*0.45))
        func mass(_ rows: ClosedRange<Int>) -> Int {
            var count = 0
            for y in rows { for column in max(0,Int(x)-centeredRadius)...min(width-1,Int(x)+centeredRadius) { count += Int(ink[y*width+column]) } }
            return count
        }
        let above = mass(max(0,row-half)...max(0,row-margin))
        let below = mass(min(height-1,row+margin)...min(height-1,row+half))
        if min(above,below) < max(4,Int(gap*0.25)) { return true }
        for column in max(0,Int(x)-radius)...min(width-1,Int(x)+radius) {
            var upper=0,lower=0
            for y in top...row { upper += Int(ink[y*width+column]) }
            for y in row...bottom { lower += Int(ink[y*width+column]) }
            // A stem can end at this string, with a real digit on the next
            // string providing unrelated lower ink. Test each half separately.
            if Double(upper)>=Double(row-top+1)*0.92 || Double(lower)>=Double(bottom-row+1)*0.92 { return true }
        }
        return false
    }

    func glyphSpans(left: Int, right: Int, row: Int, gap: Double) -> [ClosedRange<Int>] {
        let ink = mask(), half = Int(gap*0.45), margin = max(2,Int(gap*0.16))
        let columns = (max(0,left)..<min(width,right)).filter { x in
            (max(0,row-half)...min(height-1,row+half)).filter { abs($0-row)>margin && ink[$0*width+x] == 1 }.count >= 2
        }
        var spans: [ClosedRange<Int>] = []
        for group in Self.groups(columns) {
            guard let first = group.first, let last = group.last else { continue }
            if let prior = spans.last, Double(first-prior.upperBound) <= gap*0.6 {
                spans[spans.count-1] = prior.lowerBound...last
            } else { spans.append(first...last) }
        }
        return spans.filter { $0.count >= max(3,Int(gap*0.25)) && Double($0.count)<=gap*2.2 }
    }

    func glyph(left: Int, right: Int, row: Int, gap: Double) -> (pixels: [UInt8], width: Int, height: Int, left: Int)? {
        let l=max(0,left),r=min(width,right),top=max(0,row-Int((gap*0.5).rounded())),bottom=min(height,row+Int((gap*0.5).rounded())+1)
        guard r>l,bottom>top else { return nil }
        return ((top..<bottom).flatMap { Array(pixels[($0*width+l)..<($0*width+r)]) },r-l,bottom-top,l)
    }

    func band(left: Int, right: Int, center: Int, gap: Double) -> (pixels: [UInt8], width: Int, height: Int, left: Int)? {
        let l = max(0,left), r = min(width,right), top = max(0,Int((Double(center)-gap*0.45).rounded())), bottom = min(height,Int((Double(center)+gap*0.45).rounded())+1)
        guard r>l, bottom>top else { return nil }
        // Reject empty strings: line ink alone is not a note. Require ink away from the centre.
        let margin = max(2,Int(gap*0.16))
        let ink = mask()
        let columns = (l..<r).filter { x in
            (top..<bottom).filter { abs($0-center)>margin && ink[$0*width+x] == 1 }.count >= max(2,Int(gap*0.18))
        }
        let content = Self.groups(columns).filter { $0.count >= max(3,Int(gap*0.2)) }
        guard let first = content.first?.first, let last = content.last?.last else { return nil }
        // Long empty prefixes harm CTC decoding on strings played only at the end
        // of a measure. Trim to actual off-line glyph ink, keeping a small border.
        let x0 = max(l,first-max(2,Int(gap*0.35))), x1 = min(r,last+max(3,Int(gap*0.35))+1)
        var band = (top..<bottom).flatMap { Array(pixels[($0*width+x0)..<($0*width+x1)]) }
        let sorted = band.sorted(), low = Int(sorted[sorted.count/50]), high = Int(sorted[sorted.count*95/100])
        if high < 215 && high-low > 15 {
            band = band.map { UInt8(min(255,max(0,(Int($0)-low)*255/(high-low)))) }
        }
        return (band,x1-x0,bottom-top,x0)
    }
}
