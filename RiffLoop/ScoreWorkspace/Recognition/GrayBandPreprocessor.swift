import Foundation

enum GrayBandError: Error {
    case invalidDimensions
    case resourceLimit
}

struct PreparedGrayBand {
    let width: Int
    let effectiveWidth: Int
    let boundedWidth: Int
    let boundedHeight: Int
    let resizedGray: [UInt8]
    let tensor: [Float]
}

/// Independent experimental port of the desktop grayscale preprocessing path.
enum GrayBandPreprocessor {
    static func prepare(_ pixels: [UInt8], width: Int, height: Int) throws -> PreparedGrayBand {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              pixels.count == width * height else { throw GrayBandError.invalidDimensions }
        var bounded = pixels
        var w = width
        var h = height
        if max(w, h) > 2000 {
            let ratio = 2000.0 / Double(max(w, h))
            let newWidth = roundedDimension(w, ratio: ratio)
            let newHeight = roundedDimension(h, ratio: ratio)
            try checkResize(width: newWidth, height: newHeight)
            bounded = resize(bounded, width: w, height: h, toWidth: newWidth, height: newHeight)
            w = newWidth
            h = newHeight
        }
        if min(w, h) < 30 {
            let ratio = 30.0 / Double(min(w, h))
            let newWidth = roundedDimension(w, ratio: ratio)
            let newHeight = roundedDimension(h, ratio: ratio)
            try checkResize(width: newWidth, height: newHeight)
            bounded = resize(bounded, width: w, height: h, toWidth: newWidth, height: newHeight)
            w = newWidth
            h = newHeight
        }

        let ratio = Double(w) / Double(h)
        let outputWidth = Int(48 * max(320.0 / 48.0, ratio))
        let effectiveWidth = min(outputWidth, Int(ceil(48 * ratio)))
        guard outputWidth > 0, outputWidth <= 3200, effectiveWidth > 0 else {
            throw GrayBandError.resourceLimit
        }
        let resized = resize(bounded, width: w, height: h, toWidth: effectiveWidth, height: 48)

        // Desktop gray input becomes three identical BGR channels. Padding is
        // normalized zero, not normalized white.
        var tensor = [Float](repeating: 0, count: 3 * 48 * outputWidth)
        for channel in 0..<3 {
            for y in 0..<48 {
                for x in 0..<effectiveWidth {
                    let value = Float(resized[y * effectiveWidth + x]) / 255
                    tensor[(channel * 48 + y) * outputWidth + x] = (value - 0.5) / 0.5
                }
            }
        }
        return PreparedGrayBand(width: outputWidth, effectiveWidth: effectiveWidth,
                                boundedWidth: w, boundedHeight: h, resizedGray: resized, tensor: tensor)
    }

    private static func roundedDimension(_ original: Int, ratio: Double) -> Int {
        let truncated = Int(Double(original) * ratio)
        return Int((Double(truncated) / 32).rounded(.toNearestOrEven)) * 32
    }

    private static func checkResize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw GrayBandError.invalidDimensions }
        guard width <= 8192, height <= 8192, width * height <= 16_000_000 else {
            throw GrayBandError.resourceLimit
        }
    }

    // Adapted from OpenCV 4.13 resize.cpp, 8-bit INTER_LINEAR fixed-point
    // implementation. Copyright and redistribution terms are retained in
    // OPENCV_RESIZE_LICENSE.txt. Not yet validated on actual mini 6 hardware.
    private static func resize(_ image: [UInt8], width: Int, height: Int,
                               toWidth: Int, height targetHeight: Int) -> [UInt8] {
        let coefficientScale: Float = 2048
        let scaleX = Double(width) / Double(toWidth)
        let scaleY = Double(height) / Double(targetHeight)
        var xs = [(Int, Int, Int, Int)]()
        xs.reserveCapacity(toWidth)
        for x in 0..<toWidth {
            let coordinate = Float((Double(x) + 0.5) * scaleX - 0.5)
            var left = Int(floor(Double(coordinate)))
            var fraction = coordinate - Float(left)
            if left < 0 || left >= width - 1 { fraction = 0 }
            let right = min(max(left + 1, 0), width - 1)
            left = min(max(left, 0), width - 1)
            let a0 = Int(((1 - fraction) * coefficientScale).rounded(.toNearestOrEven))
            let a1 = Int((fraction * coefficientScale).rounded(.toNearestOrEven))
            xs.append((left, right, a0, a1))
        }
        var result = [UInt8](repeating: 0, count: toWidth * targetHeight)
        for y in 0..<targetHeight {
            let coordinate = Float((Double(y) + 0.5) * scaleY - 0.5)
            let rawTop = Int(floor(Double(coordinate)))
            let fraction = coordinate - Float(rawTop)
            let top = min(max(rawTop, 0), height - 1)
            let bottom = min(max(rawTop + 1, 0), height - 1)
            let b0 = Int(((1 - fraction) * coefficientScale).rounded(.toNearestOrEven))
            let b1 = Int((fraction * coefficientScale).rounded(.toNearestOrEven))
            for x in 0..<toWidth {
                let (left, right, a0, a1) = xs[x]
                let upper = Int(image[top * width + left]) * a0 + Int(image[top * width + right]) * a1
                let lower = Int(image[bottom * width + left]) * a0 + Int(image[bottom * width + right]) * a1
                let value = (((b0 * (upper >> 4)) >> 16) + ((b1 * (lower >> 4)) >> 16) + 2) >> 2
                result[y * toWidth + x] = UInt8(clamping: value)
            }
        }
        return result
    }
}
