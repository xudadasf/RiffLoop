import Foundation

/// Experimental grayscale path. Large/small inputs requiring RapidOCR's
/// separate bounds resize are rejected until that stage is verified.
enum GrayBandError: Error {
    case invalidDimensions
    case unsupportedBoundsResize
}

struct PreparedGrayBand {
    let width: Int
    let effectiveWidth: Int
    let resizedGray: [UInt8]
    let tensor: [Float]
}

enum GrayBandPreprocessor {
    static func prepare(_ pixels: [UInt8], width: Int, height: Int) throws -> PreparedGrayBand {
        guard width > 0, height > 0, width <= 2000, height <= 2000,
              pixels.count == width * height else { throw GrayBandError.invalidDimensions }
        guard min(width, height) >= 30 else { throw GrayBandError.unsupportedBoundsResize }

        let ratio = Double(width) / Double(height)
        let outputWidth = Int(48 * max(320.0 / 48.0, ratio))
        let effectiveWidth = min(outputWidth, Int(ceil(48 * ratio)))
        guard outputWidth > 0, outputWidth <= 3200, effectiveWidth > 0 else {
            throw GrayBandError.invalidDimensions
        }

        // Center-aligned bilinear sampling, with replicated edge pixels. OpenCV
        // uses fixed-point optimizations, so individual values can differ by one
        // grayscale level; the independent fixture measures those differences.
        var resized = [UInt8](repeating: 0, count: 48 * effectiveWidth)
        for y in 0..<48 {
            let sourceY = (Double(y) + 0.5) * Double(height) / 48.0 - 0.5
            let rawY = Int(floor(sourceY))
            let weightY = sourceY - Double(rawY)
            let y0 = min(max(rawY, 0), height - 1)
            let y1 = min(max(rawY + 1, 0), height - 1)
            for x in 0..<effectiveWidth {
                let sourceX = (Double(x) + 0.5) * Double(width) / Double(effectiveWidth) - 0.5
                let rawX = Int(floor(sourceX))
                let weightX = sourceX - Double(rawX)
                let x0 = min(max(rawX, 0), width - 1)
                let x1 = min(max(rawX + 1, 0), width - 1)
                let upper = Double(pixels[y0 * width + x0]) * (1 - weightX) +
                    Double(pixels[y0 * width + x1]) * weightX
                let lower = Double(pixels[y1 * width + x0]) * (1 - weightX) +
                    Double(pixels[y1 * width + x1]) * weightX
                let value = (upper * (1 - weightY) + lower * weightY).rounded(.toNearestOrEven)
                resized[y * effectiveWidth + x] = UInt8(min(max(value, 0), 255))
            }
        }

        // The desktop gray input is expanded to three identical BGR channels;
        // padding is the normalized value 0, not normalized white.
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
                                resizedGray: resized, tensor: tensor)
    }
}
