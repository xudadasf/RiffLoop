import XCTest
@testable import RiffLoop

final class RiffLoopDocumentStoreTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func testCreatesTheThreeFilesVisiblePracticeFolders() throws {
        let store = RiffLoopDocumentStore(documentsURL: temporaryRoot)

        try store.prepareDirectories()

        for folder in ["PDF", "视频", "GP"] {
            var isDirectory = ObjCBool(false)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: temporaryRoot.appendingPathComponent(folder).path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testLibraryOnlyListsSupportedFilesForItsMode() throws {
        let store = RiffLoopDocumentStore(documentsURL: temporaryRoot)
        try store.prepareDirectories()
        let gpFolder = store.folderURL(for: .guitarPro)
        FileManager.default.createFile(
            atPath: gpFolder.appendingPathComponent("此生不换.gp").path,
            contents: Data([1])
        )
        FileManager.default.createFile(
            atPath: gpFolder.appendingPathComponent("说明.txt").path,
            contents: Data([2])
        )

        XCTAssertEqual(
            try store.files(for: .guitarPro).map(\.lastPathComponent),
            ["此生不换.gp"]
        )
    }

    func testImportAddsANumberedSuffixWithoutOverwriting() throws {
        let store = RiffLoopDocumentStore(documentsURL: temporaryRoot)
        try store.prepareDirectories()
        let source = temporaryRoot.appendingPathComponent("practice.mp4")
        try Data([1, 2, 3]).write(to: source)

        let first = try store.importFile(from: source, for: .video)
        let second = try store.importFile(from: source, for: .video)

        XCTAssertEqual(first.lastPathComponent, "practice.mp4")
        XCTAssertEqual(second.lastPathComponent, "practice (2).mp4")
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
    }

    func testPdfAudioLibraryIgnoresDirectoriesWithAudioExtensions() throws {
        let store = RiffLoopDocumentStore(documentsURL: temporaryRoot)
        try store.prepareDirectories()
        try FileManager.default.createDirectory(
            at: store.folderURL(for: .pdf).appendingPathComponent("不是伴奏.mp3"),
            withIntermediateDirectories: false
        )

        XCTAssertTrue(try store.pdfAudioFiles().isEmpty)
    }

    func testDeleteFileRemovesAFileInsideTheRequestedLibrary() throws {
        let store = RiffLoopDocumentStore(documentsURL: temporaryRoot)
        try store.prepareDirectories()
        let file = store.folderURL(for: .guitarPro)
            .appendingPathComponent("待删除.gp")
        try Data([1, 2, 3]).write(to: file)

        try store.deleteFile(file, for: .guitarPro)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteFileSupportsPdfLibraryFiles() throws {
        let store = RiffLoopDocumentStore(documentsURL: temporaryRoot)
        try store.prepareDirectories()
        let file = store.folderURL(for: .pdf)
            .appendingPathComponent("待删除.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: file)

        try store.deleteFile(file, for: .pdf)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteFileRejectsAFileOutsideTheRequestedLibrary() throws {
        let store = RiffLoopDocumentStore(documentsURL: temporaryRoot)
        try store.prepareDirectories()
        let video = store.folderURL(for: .video)
            .appendingPathComponent("不要误删.mp4")
        try Data([4, 5, 6]).write(to: video)

        XCTAssertThrowsError(try store.deleteFile(video, for: .guitarPro))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }
}
