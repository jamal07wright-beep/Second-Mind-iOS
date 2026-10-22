//
// TextTools.swift
//
// Small text helpers: put lines in reading order, and tell whether new text
// is really new or the same page seen again.
//

import CoreGraphics
import Foundation

enum TextTools {
  /// Top to bottom, then left to right. Lines whose centers are close in
  /// height count as the same row.
  static func readingOrder(_ lines: [TextLine], rowHeight: CGFloat = 0.015) -> String {
    let sorted = lines.sorted { a, b in
      let rowA = Int(((1 - a.box.midY) / rowHeight).rounded(.down))
      let rowB = Int(((1 - b.box.midY) / rowHeight).rounded(.down))
      if rowA != rowB { return rowA < rowB }
      return a.box.minX < b.box.minX
    }
    return sorted.map(\.text).joined(separator: "\n")
  }

  static func words(_ text: String) -> Set<String> {
    Set(
      text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    )
  }

  /// 0 means nothing in common, 1 means the same words.
  static func similarity(_ a: String, _ b: String) -> Double {
    let wa = words(a)
    let wb = words(b)
    if wa.isEmpty && wb.isEmpty { return 1 }
    let union = wa.union(wb).count
    return union == 0 ? 0 : Double(wa.intersection(wb).count) / Double(union)
  }

  static func isNew(_ text: String, comparedTo previous: String?) -> Bool {
    guard let previous, !previous.isEmpty else { return true }
    return similarity(text, previous) < 0.8
  }

  /// Ignore specks the camera mistakes for letters.
  static func hasRealWords(_ text: String) -> Bool {
    text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 3
  }
}
