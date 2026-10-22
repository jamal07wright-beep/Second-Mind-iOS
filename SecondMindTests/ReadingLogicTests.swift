//
// ReadingLogicTests.swift
//
// Plain logic checks: stillness, reading order, repeat detection, and
// on-phone text recognition on a made-up page.
//

@testable import SecondMind
import UIKit
import XCTest

final class StillnessDetectorTests: XCTestCase {
  private func flat(_ value: UInt8) -> [UInt8] { [UInt8](repeating: value, count: 24 * 24) }

  func testReadsAfterHoldingStill() {
    var detector = StillnessDetector()
    detector.requiredStillFrames = 3
    XCTAssertFalse(detector.feed(flat(100)))  // first frame, nothing to compare
    XCTAssertFalse(detector.feed(flat(100)))
    XCTAssertFalse(detector.feed(flat(101)))
    XCTAssertTrue(detector.feed(flat(100)))
  }

  func testDoesNotRepeatWithoutMovement() {
    var detector = StillnessDetector()
    detector.requiredStillFrames = 2
    _ = detector.feed(flat(100))
    _ = detector.feed(flat(100))
    XCTAssertTrue(detector.feed(flat(100)))
    for _ in 0..<10 {
      XCTAssertFalse(detector.feed(flat(100)), "Same view should not read twice")
    }
  }

  func testMovementRearms() {
    var detector = StillnessDetector()
    detector.requiredStillFrames = 2
    _ = detector.feed(flat(100))
    _ = detector.feed(flat(100))
    XCTAssertTrue(detector.feed(flat(100)))
    XCTAssertFalse(detector.feed(flat(220)))  // big change: new page
    XCTAssertFalse(detector.feed(flat(220)))
    XCTAssertTrue(detector.feed(flat(220)))
  }

  func testShakyViewNeverReads() {
    var detector = StillnessDetector()
    for i in 0..<30 {
      XCTAssertFalse(detector.feed(flat(i.isMultiple(of: 2) ? 40 : 200)))
    }
  }

  func testThumbnailSize() {
    let image = TestImages.page(lines: ["HELLO"])
    XCTAssertEqual(StillnessDetector.thumbnail(of: image).count, 24 * 24)
  }
}

final class TextToolsTests: XCTestCase {
  func testReadingOrderTopToBottomLeftToRight() {
    let lines = [
      TextLine(text: "bottom", box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)),
      TextLine(text: "right", box: CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.05)),
      TextLine(text: "left", box: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)),
    ]
    XCTAssertEqual(TextTools.readingOrder(lines), "left\nright\nbottom")
  }

  func testSameTextIsNotNew() {
    XCTAssertFalse(TextTools.isNew("Exit on the left", comparedTo: "exit on the LEFT"))
    XCTAssertTrue(TextTools.isNew("Platform 2 trains", comparedTo: "Exit on the left"))
    XCTAssertTrue(TextTools.isNew("Anything", comparedTo: nil))
  }

  func testIgnoresSpecks() {
    XCTAssertFalse(TextTools.hasRealWords("| . 1"))
    XCTAssertTrue(TextTools.hasRealWords("Stop"))
  }
}

final class TextRecognizerTests: XCTestCase {
  func testRecognizesPrintedWords() async throws {
    let image = TestImages.page(lines: ["THE QUICK BROWN FOX", "JUMPS OVER THE DOG"])
    let text = try await TextRecognizer.recognize(image)
    XCTAssertTrue(text.uppercased().contains("QUICK"), "Got: \(text)")
    XCTAssertTrue(text.uppercased().contains("JUMPS"), "Got: \(text)")
    let quick = text.uppercased().range(of: "QUICK")
    let jumps = text.uppercased().range(of: "JUMPS")
    if let quick, let jumps {
      XCTAssertLessThan(quick.lowerBound, jumps.lowerBound, "Top line should come first")
    }
  }
}

enum TestImages {
  /// Black words on a white page, big and clear.
  static func page(lines: [String], size: CGSize = CGSize(width: 900, height: 600)) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 56),
        .foregroundColor: UIColor.black,
      ]
      for (index, line) in lines.enumerated() {
        (line as NSString).draw(at: CGPoint(x: 40, y: 80 + CGFloat(index) * 110), withAttributes: attributes)
      }
    }
  }

  static func writePNG(_ image: UIImage, name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try XCTUnwrap(image.pngData()).write(to: url)
    return url
  }
}
