import Foundation

struct PdfReadingPoint: Codable, Equatable, Sendable {
    let time: TimeInterval
    let pageIndex: Int
    let verticalProgress: Double

    var normalized: Self {
        PdfReadingPoint(
            time: max(0, time),
            pageIndex: max(0, pageIndex),
            verticalProgress: min(max(verticalProgress, 0), 1)
        )
    }
}

struct PdfReadingTarget: Equatable, Sendable {
    let pageIndex: Int
    let verticalProgress: Double
}

func pdfReadingTarget(
    at time: TimeInterval,
    points: [PdfReadingPoint]
) -> PdfReadingTarget? {
    guard !points.isEmpty else { return nil }
    let ordered = points.map(\.normalized).sorted { $0.time < $1.time }
    let previous = ordered.last { $0.time <= time } ?? ordered[0]
    guard let next = ordered.first(where: { $0.time > time }) else {
        return PdfReadingTarget(
            pageIndex: previous.pageIndex,
            verticalProgress: previous.verticalProgress
        )
    }
    guard previous.pageIndex == next.pageIndex, next.time > previous.time else {
        return PdfReadingTarget(
            pageIndex: previous.pageIndex,
            verticalProgress: previous.verticalProgress
        )
    }
    let fraction = min(max((time - previous.time) / (next.time - previous.time), 0), 1)
    return PdfReadingTarget(
        pageIndex: previous.pageIndex,
        verticalProgress: min(
            max(previous.verticalProgress + (next.verticalProgress - previous.verticalProgress) * fraction, 0),
            1
        )
    )
}

func recordPdfReadingPoint(
    _ point: PdfReadingPoint,
    in existing: [PdfReadingPoint],
    force: Bool = false
) -> [PdfReadingPoint] {
    let safePoint = point.normalized
    let ordered = existing.map(\.normalized).sorted { $0.time < $1.time }
    let retained = ordered.filter { $0.time < safePoint.time }
    let previous = retained.last
    let overwritesFuture = ordered.contains { $0.time >= safePoint.time }
    let shouldRecord = previous == nil
        || force
        || overwritesFuture
        || previous?.pageIndex != safePoint.pageIndex
        || safePoint.time - (previous?.time ?? 0) >= 0.25
        || abs(safePoint.verticalProgress - (previous?.verticalProgress ?? 0)) >= 0.03
    return shouldRecord ? retained + [safePoint] : ordered
}
