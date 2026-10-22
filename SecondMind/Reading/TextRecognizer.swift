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
  /// Big photos are shrunk to this long side first. Still sharp enough for
  /// print, and much faster.
  static let maxSide = 1600

  static func recognize(_ image: UIImage) async throws -> String {
    guard let original = image.cgImage else { return "" }
    let orientation = CGImagePropertyOrientation(image.imageOrientation)
    return try await Task.detached(priority: .userInitiated) {
      let cg = shrink(original, maxSide: maxSide)
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["en-US"]
      request.automaticallyDetectsLanguage = false
      try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
      let lines: [TextLine] = (request.results ?? []).compactMap { observation in
        guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
        return TextLine(text: best.string, box: observation.boundingBox)
      }
      return TextTools.readingOrder(lines)
    }.value
  }

  static func shrink(_ image: CGImage, maxSide: Int) -> CGImage {
    let longSide = max(image.width, image.height)
    guard longSide > maxSide else { return image }
    let scale = Double(maxSide) / Double(longSide)
    let width = Int(Double(image.width) * scale)
    let height = Int(Double(image.height) * scale)
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
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
