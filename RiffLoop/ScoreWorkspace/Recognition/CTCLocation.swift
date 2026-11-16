import Foundation

enum CTCLocationError: Error {
    case invalidGeometry
    case invalidRun
}

struct CTCLocatedRun: Equatable {
    let run: PartialCTCResult.Run
    let x: Double
    let isWithinSource: Bool
}

/// Desktop RapidOCR's model-column mapping, isolated from production code.
/// A column denotes the first selected time step, not the glyph centre.
enum CTCLocation {
    static func locate(_ runs: [PartialCTCResult.Run], timeSteps: Int,
                       boundedWidth: Int, boundedHeight: Int,
                       sourceLeft: Double, sourceRight: Double) throws -> [CTCLocatedRun] {
        guard timeSteps > 0, boundedWidth > 0, boundedHeight > 0,
              sourceLeft.isFinite, sourceRight.isFinite, sourceRight > sourceLeft else {
            throw CTCLocationError.invalidGeometry
        }
        let ratio = Double(boundedWidth) / Double(boundedHeight)
        let maxRatio = max(320.0 / 48.0, ratio)
        let lineLength = Double(timeSteps) * ratio / maxRatio
        guard lineLength.isFinite, lineLength > 0 else { throw CTCLocationError.invalidGeometry }

        return try runs.map { run in
            guard run.start >= 0, run.start <= run.end, run.end < timeSteps else {
                throw CTCLocationError.invalidRun
            }
            // Preserve all CTC runs, including whitespace, so a separator
            // never disappears before grouping and can be reviewed with its score.
            let x = sourceLeft + Double(run.start) * (sourceRight - sourceLeft) / lineLength
            guard x.isFinite else { throw CTCLocationError.invalidGeometry }
            // Source crop follows the desktop's half-open [x0, x1) convention.
            return CTCLocatedRun(run: run, x: x,
                                 isWithinSource: x >= sourceLeft && x < sourceRight)
        }
    }
}
