//
// StillnessDetector.swift
//
// Decides when the view has held still long enough to read. Each frame is
// shrunk to a tiny grayscale grid and compared with the one before. After a
// read it waits for real movement (a new page, looking somewhere else)
// before it will fire again, so the same page isn't read over and over.
//

import CoreGraphics
import UIKit

struct StillnessDetector {
  /// Average change below this counts as "holding still" (0 to 1 scale).
  var stillThreshold: Double = 0.035
  /// Average change above this counts as "moved to something new".
  var moveThreshold: Double = 0.09
  /// How many still frames in a row before reading. At 7 fps, 5 is about 0.7 s.
  var requiredStillFrames: Int = 5

  private(set) var stillCount = 0
  private(set) var armed = true
  private var previous: [UInt8]?

  /// Feeds one thumbnail. Returns true when it's time to read.
  mutating func feed(_ thumbnail: [UInt8]) -> Bool {
    defer { previous = thumbnail }
    guard let last = previous, last.count == thumbnail.count, !thumbnail.isEmpty else {
      stillCount = 0
      return false
    }
    let change = Self.difference(last, thumbnail)
    if change < stillThreshold {
      stillCount += 1
    } else {
      stillCount = 0
      if change > moveThreshold { armed = true }
    }
    if armed, stillCount >= requiredStillFrames {
      armed = false
      return true
    }
    return false
  }

  /// Lets the next still moment trigger a read even without movement.
  mutating func rearm() {
    armed = true
    stillCount = 0
  }

  mutating func reset() {
    armed = true
    stillCount = 0
    previous = nil
  }

  static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var total = 0
    for i in 0..<min(a.count, b.count) {
      total += abs(Int(a[i]) - Int(b[i]))
    }
    return Double(total) / Double(max(a.count, 1) * 255)
  }

  /// Shrinks an image to a side x side grayscale grid.
  static func thumbnail(of image: UIImage, side: Int = 24) -> [UInt8] {
    guard let cg = image.cgImage else { return [] }
    var pixels = [UInt8](repeating: 0, count: side * side)
    let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: side,
          height: side,
          bitsPerComponent: 8,
          bytesPerRow: side,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
      else { return false }
      context.interpolationQuality = .low
      context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    return drew ? pixels : []
  }
}
