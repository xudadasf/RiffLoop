import Foundation

enum ScoreRegionCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var title: String {
        switch self {
        case .topLeft: "左上角"
        case .topRight: "右上角"
        case .bottomLeft: "左下角"
        case .bottomRight: "右下角"
        }
    }
}

extension ScoreRegion {
    /// Translation is measured in the displayed page's normalized coordinates.
    /// Keep the opposite corner fixed; crossing it clamps instead of flipping.
    func resized(corner: ScoreRegionCorner, dx: Double, dy: Double) -> ScoreRegion {
        guard isValid, dx.isFinite, dy.isFinite else { return self }
        let minimum = 0.005
        let left = corner.isLeft ? min(max(0, x + dx), x + width - min(width, minimum)) : x
        let right = corner.isLeft ? x + width : max(min(1, x + width + dx), x + min(width, minimum))
        let top = corner.isTop ? min(max(0, y + dy), y + height - min(height, minimum)) : y
        let bottom = corner.isTop ? y + height : max(min(1, y + height + dy), y + min(height, minimum))
        return ScoreRegion(id: id, x: left, y: top, width: right - left, height: bottom - top)
    }
}
