import XCTest
import UIKit
import PDFKit
@testable import RiffLoop

final class TabRecognitionTests: XCTestCase {
    func testImageAndPDFRegionsOrderGapsAndEditableOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = UIGraphicsImageRendererFormat(); format.scale=1;format.opaque=true
        let image = UIGraphicsImageRenderer(size:CGSize(width:800,height:240),format:format).image { context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:800,height:240))
            let cg=context.cgContext;cg.setStrokeColor(UIColor.black.cgColor);cg.setLineWidth(1)
            for y in stride(from:60,through:160,by:20) { cg.move(to:CGPoint(x:20,y:y));cg.addLine(to:CGPoint(x:780,y:y));cg.strokePath() }
            for x in [20,780] { cg.move(to:CGPoint(x:x,y:60));cg.addLine(to:CGPoint(x:x,y:160));cg.strokePath() }
            for (index,value) in [5,8,6,8].enumerated() {
                let box=CGRect(x:110+index*170,y:147,width:25,height:27)
                UIColor.white.setFill();context.fill(box)
                (String(value) as NSString).draw(at:box.origin,withAttributes:[.font:UIFont.systemFont(ofSize:23),.foregroundColor:UIColor.black])
            }
        }
        let png=folder.appendingPathComponent("synthetic.png"),pdf=folder.appendingPathComponent("synthetic.pdf")
        try XCTUnwrap(image.pngData()).write(to:png)
        let document=PDFDocument();document.insert(try XCTUnwrap(PDFPage(image:image)),at:0);XCTAssertTrue(document.write(to:pdf))
        var materials:[ScoreSequenceMaterial]=[],refs:[ScoreSequenceRegionReference]=[]
        var urls:[String:URL]=[:]
        for url in [png,pdf] {
            let store=ScoreRegionsStore(source:url);try await store.bindSource()
            let region=ScoreRegion(x:0,y:0,width:1,height:1)
            try await store.savePage(index:0,rotation:0,regions:[region],replacing:[])
            let snapshot=try await store.snapshot()
            let material=ScoreSequenceMaterial(name:url.lastPathComponent,sourceDigest:snapshot.sourceDigest)
            materials.append(material);refs.append(.init(material:material,pageIndex:0,rotation:0,regionID:region.id));urls[material.name]=url
        }
        var plan=try ScoreSequencePlan(materials:materials,regions:refs)
        try plan.assign(number:2,toPosition:0)
        try plan.setGapAfter(2,number:2)
        try plan.setRecognitionSettings(.init(tempo:70,numerator:3,denominator:4,tuning:[40,45,50,55,59,64]))
        let regions=try await TabRecognitionPipeline.regions(plan:plan,materialURLs:urls)
        let result=try await TabRecognitionPipeline.shared.recognize(regions:regions,settings:plan.effectiveSettings) { _,_ in }
        XCTAssertEqual(result.tempo,70);XCTAssertEqual(result.numerator,3)
        XCTAssertEqual(result.bars.count,4)
        XCTAssertEqual(result.bars[0].source?.name,"synthetic.pdf")
        XCTAssertNil(result.bars[1].source);XCTAssertNil(result.bars[2].source)
        XCTAssertEqual(result.bars[3].source?.name,"synthetic.png")
        for index in [0,3] {
            XCTAssertEqual(result.bars[index].beats.flatMap(\.notes).map(\.fret),[5,8,6,8])
            XCTAssertTrue(result.bars[index].beats.flatMap(\.notes).allSatisfy { $0.string == 6 })
        }
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath:png.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:pdf.path))
    }

    func testNoStringsGivesEditableFallbackInsteadOfEmptyResult() async throws {
        let settings=ScoreRecognitionSettings.standard
        let region=TabRecognitionRegion(url:URL(fileURLWithPath:"/nonexistent-riffloop-score.png"),source:.init(name:"missing.png",digest:String(repeating:"a",count:64),page:0,region:.init(x:0,y:0,width:1,height:1)),rotation:0,gapAfter:0)
        let draft=try await TabRecognitionPipeline.shared.recognize(regions:[region],settings:settings) { _,_ in }
        XCTAssertEqual(draft.bars.count,1);XCTAssertTrue(draft.isComplete)
        XCTAssertTrue(draft.bars[0].beats.flatMap(\.notes).isEmpty)
        XCTAssertFalse(draft.bars[0].review.isEmpty)
    }
    func testSixLinesRejectFiveLinesAndKeepActualBarCount() throws {
        let image = synthetic(strings: 6)
        let raster = try TabRaster(image: XCTUnwrap(image.cgImage))
        let systems = raster.systems()
        XCTAssertEqual(systems.count, 1)
        XCTAssertEqual(systems.first?.boundaries.count, 5)
        XCTAssertEqual(systems.first?.rows.count, 6)
        XCTAssertTrue(try TabRaster(image: XCTUnwrap(synthetic(strings: 5).cgImage)).systems().isEmpty)
    }

    func testDeskewAndShadowKeepSixStrings() throws {
        let image = synthetic(strings: 6, slope: 0.035, shadow: true)
        let raster = try TabRaster(image: XCTUnwrap(image.cgImage)).deskewed()
        XCTAssertEqual(raster.systems().count, 1)
        XCTAssertEqual(raster.systems().first?.boundaries.count, 5)
    }

    func testDigitModelReadsKnownStringBand() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 40), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0,y: 0,width: 400,height: 40))
            ("5   8   6   8   7   8" as NSString).draw(at: CGPoint(x: 10,y: 6), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
        }
        let raster = try TabRaster(image: XCTUnwrap(image.cgImage))
        let digits = try TabDigitRecognizer().recognize(raster.pixels, width: raster.width, height: raster.height, gap: 24)
        XCTAssertEqual(digits.compactMap(\.fret), [5,8,6,8,7,8])
    }

    private func synthetic(strings: Int, slope: CGFloat = 0, shadow: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 900,height: 260), format: format).image { context in
            let c = context.cgContext
            UIColor.white.setFill(); context.fill(CGRect(x: 0,y: 0,width: 900,height: 260))
            if shadow { for x in 0..<900 { c.setFillColor(gray: 0.55+0.45*CGFloat(x)/900, alpha: 1); c.fill(CGRect(x:x,y:0,width:1,height:260)) } }
            c.setStrokeColor(UIColor.black.cgColor); c.setLineWidth(2)
            for i in 0..<strings { let y = CGFloat(70+i*20); c.move(to: CGPoint(x:30,y:y)); c.addLine(to:CGPoint(x:870,y:y+slope*840)); c.strokePath() }
            for x in [30,240,450,660,870] { let y = 70+slope*CGFloat(x-30); c.move(to:CGPoint(x:CGFloat(x),y:y)); c.addLine(to:CGPoint(x:CGFloat(x),y:y+CGFloat(strings-1)*20)); c.strokePath() }
        }
    }
}
