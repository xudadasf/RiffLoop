import XCTest
import UIKit
@testable import RiffLoop

final class TabRecognitionTests: XCTestCase {
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
