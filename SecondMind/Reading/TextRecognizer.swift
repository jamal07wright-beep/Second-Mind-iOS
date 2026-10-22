//
// TextRecognizer.swift
//
// On-phone text recognition with Apple's Vision. Nothing leaves the phone.
//

import UIKit
import Vision

struct TextLine: Equatable {
  var text: String
  /// Vision coordinates: 0 to 1, origin at bottom left.
  var box: CGRect
}

enum TextRecognizer {
  static func recognize(_ image: UIImage) async throws -> String {
    guard let cg = image.cgImage else { return "" }
    let orientation = CGImagePropertyOrientation(image.imageOrientation)
    return try await Task.detached(priority: .userInitiated) {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
      let lines: [TextLine] = (request.results ?? []).compactMap { observation in
        guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
        return TextLine(text: best.string, box: observation.boundingBox)
      }
      return TextTools.readingOrder(lines)
    }.value
  }
}

extension CGImagePropertyOrientation {
  init(_ orientation: UIImage.Orientation) {
    switch orientation {
    case .up: self = .up
    case .down: self = .down
    case .left: self = .left
    case .right: self = .right
    case .upMirrored: self = .upMirrored
    case .downMirrored: self = .downMirrored
    case .leftMirrored: self = .leftMirrored
    case .rightMirrored: self = .rightMirrored
    @unknown default: self = .up
    }
  }
}
