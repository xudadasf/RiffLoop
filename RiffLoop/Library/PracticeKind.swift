import Foundation

enum PracticeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case video
    case guitarPro
    case pdf

    var id: Self { self }

    var title: String {
        switch self {
        case .video: "视频练习"
        case .guitarPro: "Guitar Pro 乐谱"
        case .pdf: "PDF 谱面"
        }
    }

    var folderName: String {
        switch self {
        case .video: "视频"
        case .guitarPro: "GP"
        case .pdf: "PDF"
        }
    }

    var supportedExtensions: Set<String> {
        switch self {
        case .video: ["mp4", "mov", "m4v"]
        case .guitarPro: ["gp", "gpx", "gp3", "gp4", "gp5"]
        case .pdf: ["pdf"]
        }
    }
}
