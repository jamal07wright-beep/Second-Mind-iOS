//
// ScreenScanner.swift
//
// Panoptic-style scan of what the glasses see, free and on the phone (Apple
// Vision): every word and number, plus boxes, lines, triangles and circles,
// each with where it sits on screen. Coach sends this map to Claude with the
// photo, so calls are sharper (the score, the clock, a spreadsheet cell),
// and it can spot something on screen the moment someone mentions it.
//

import CoreGraphics
import simd
import Vision

struct ScreenScan: Sendable {
  struct Item: Sendable {
    var kind: String
    var text: String
    var zone: String
    /// Vision coordinates: 0 to 1, origin bottom left.
    var box: CGRect
  }

  var words: [Item] = []
  var shapes: [Item] = []
  /// Long thin lines that cross the screen, like spreadsheet gridlines.
  var gridRows = 0
  var gridColumns = 0

  /// A short map of the screen for Claude.
  var summary: String {
    var parts: [String] = []
    if !words.isEmpty {
      let list = words.prefix(40).map { "\($0.zone): \"\($0.text.prefix(40))\"" }
      parts.append("Text: " + list.joined(separator: "; "))
    }
    if !shapes.isEmpty {
      var counts: [String: [String]] = [:]
      for shape in shapes { counts[shape.kind, default: []].append(shape.zone) }
      let list = counts.sorted { $0.key < $1.key }.map { kind, zones in
        let places = Array(Set(zones)).sorted().joined(separator: ", ")
        return "\(zones.count) \(kind)\(zones.count == 1 ? "" : "s") (\(places))"
      }
      parts.append("Shapes: " + list.joined(separator: "; "))
    }
    if gridRows >= 3, gridColumns >= 2 {
      parts.append("Looks like a table or spreadsheet, about \(gridRows) rows by \(gridColumns) columns.")
    }
    return parts.isEmpty ? "" : "On-device screen scan:\n" + parts.joined(separator: "\n")
  }

  /// On-screen text that matches words from something someone said.
  func find(_ said: String) -> [Item] {
    let skip: Set<String> = ["the", "and", "that", "this", "what", "with", "your", "you", "are", "was", "for", "have", "just", "like", "they", "them", "there", "where", "when", "then", "from", "about"]
    let keys = said.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
      .filter { $0.count >= 3 && !skip.contains($0) }
    guard !keys.isEmpty else { return [] }
    return words.filter { item in
      let text = item.text.lowercased()
      return keys.contains { text.contains($0) }
    }
  }
}

enum ScreenScanner {
  /// Runs all the scans on one frame. Takes about half a second; call off the main thread.
  static func scan(_ image: CGImage) -> ScreenScan {
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = false  // keep numbers and cell values exact
    let contours = VNDetectContoursRequest()
    contours.contrastAdjustment = 1.5
    contours.maximumImageDimension = 512
    let handler = VNImageRequestHandler(cgImage: image)
    try? handler.perform([text, contours])

    var scan = ScreenScan()
    for observation in text.results ?? [] {
      guard let best = observation.topCandidates(1).first, best.confidence > 0.3 else { continue }
      scan.words.append(.init(kind: "text", text: best.string, zone: zone(observation.boundingBox), box: observation.boundingBox))
    }
    // Read top to bottom, left to right.
    scan.words.sort { abs($0.box.midY - $1.box.midY) > 0.02 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }

    if let found = contours.results?.first {
      var rows = 0
      var columns = 0
      var shapes: [ScreenScan.Item] = []
      var queue = found.topLevelContours
      var looked = 0
      while !queue.isEmpty, looked < 400 {
        let contour = queue.removeFirst()
        looked += 1
        queue.append(contentsOf: contour.childContours)
        guard let simple = try? contour.polygonApproximation(epsilon: 0.012) else { continue }
        let box = bounds(simple.normalizedPoints)
        let area = box.width * box.height
        let thin = min(box.width, box.height)
        let long = max(box.width, box.height)
        if thin < 0.012, long > 0.5 {
          if box.width > box.height { rows += 1 } else { columns += 1 }
          continue
        }
        if thin < 0.015, long > 0.08 {
          shapes.append(.init(kind: "line", text: "", zone: zone(box), box: box))
          continue
        }
        guard area > 0.002, area < 0.8, let kind = name(simple.pointCount, box: box, points: contour.normalizedPoints) else { continue }
        shapes.append(.init(kind: kind, text: "", zone: zone(box), box: box))
      }
      // Biggest first, and not so many that the map gets noisy.
      scan.shapes = Array(shapes.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }.prefix(25))
      scan.gridRows = rows
      scan.gridColumns = columns
    }
    return scan
  }

  /// Where on screen, in words: "top left", "center", "bottom right".
  static func zone(_ box: CGRect) -> String {
    let row = box.midY > 0.66 ? "top" : box.midY < 0.33 ? "bottom" : "middle"
    let column = box.midX < 0.33 ? "left" : box.midX > 0.66 ? "right" : "center"
    if row == "middle" { return column == "center" ? "center" : "middle \(column)" }
    return "\(row) \(column)"
  }

  /// Shape name from the corners of its simplified outline.
  static func name(_ corners: Int, box: CGRect, points: [SIMD2<Float>]) -> String? {
    switch corners {
    case 3: return "triangle"
    case 4: return abs(box.width - box.height) < 0.03 ? "square" : "box"
    case 5, 6: return corners == 5 ? "pentagon" : "hexagon"
    default:
      guard corners >= 8, isRound(points, box: box) else { return nil }
      return "circle"
    }
  }

  /// Every point is about the same distance from the middle.
  static func isRound(_ points: [SIMD2<Float>], box: CGRect) -> Bool {
    guard points.count >= 8 else { return false }
    let center = SIMD2(Float(box.midX), Float(box.midY))
    let distances = points.map { simd_length($0 - center) }
    let mean = distances.reduce(0, +) / Float(distances.count)
    guard mean > 0 else { return false }
    let spread = distances.map { abs($0 - mean) }.reduce(0, +) / Float(distances.count)
    return spread / mean < 0.12
  }

  static func bounds(_ points: [SIMD2<Float>]) -> CGRect {
    guard let first = points.first else { return .zero }
    var low = first
    var high = first
    for point in points {
      low = simd_min(low, point)
      high = simd_max(high, point)
    }
    return CGRect(x: CGFloat(low.x), y: CGFloat(low.y), width: CGFloat(high.x - low.x), height: CGFloat(high.y - low.y))
  }
}
