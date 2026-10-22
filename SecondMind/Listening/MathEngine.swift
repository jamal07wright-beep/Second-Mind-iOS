//
// MathEngine.swift
//
// The real calculator behind Math. Claude only turns words into an
// expression and explains; the number itself always comes from here.
//

import Foundation

enum MathEngine {
  /// Rough check for "this line asks for math", so Claude is only asked when it's likely.
  static func looksLikeMath(_ text: String) -> Bool {
    let lower = text.lowercased()
    let digits = lower.filter(\.isNumber).count
    guard digits >= 1 else { return false }
    let cues = [
      "how much", "how many", "what's", "what is", "percent", "%", "times", "divided", "plus",
      "minus", "split", "each", "total", "tip", "half of", "double", "per", "x ", "*", "+", "/",
    ]
    return cues.contains { lower.contains($0) }
  }

  /// Only digits, spaces, decimal points, + - * / and parentheses are allowed.
  static func isSafe(_ expression: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "0123456789.+-*/() ")
    return !expression.isEmpty && expression.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  /// Evaluates a safe expression. Returns nil if it isn't safe or doesn't parse.
  static func evaluate(_ expression: String) -> Double? {
    guard isSafe(expression) else { return nil }
    var parser = Parser(chars: Array(expression.filter { $0 != " " }))
    guard let value = parser.expression(), parser.index == parser.chars.count, value.isFinite else {
      return nil
    }
    return value
  }

  /// Small recursive-descent parser: expression = term (+|- term)*, term = factor (*|/ factor)*.
  private struct Parser {
    let chars: [Character]
    var index = 0

    mutating func expression() -> Double? {
      guard var value = term() else { return nil }
      while index < chars.count, chars[index] == "+" || chars[index] == "-" {
        let op = chars[index]
        index += 1
        guard let right = term() else { return nil }
        value = op == "+" ? value + right : value - right
      }
      return value
    }

    mutating func term() -> Double? {
      guard var value = factor() else { return nil }
      while index < chars.count, chars[index] == "*" || chars[index] == "/" {
        let op = chars[index]
        index += 1
        guard let right = factor() else { return nil }
        if op == "/" && right == 0 { return nil }
        value = op == "*" ? value * right : value / right
      }
      return value
    }

    mutating func factor() -> Double? {
      guard index < chars.count else { return nil }
      if chars[index] == "-" {
        index += 1
        return factor().map { -$0 }
      }
      if chars[index] == "(" {
        index += 1
        guard let value = expression(), index < chars.count, chars[index] == ")" else { return nil }
        index += 1
        return value
      }
      let start = index
      while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
      guard index > start else { return nil }
      return Double(String(chars[start..<index]))
    }
  }

  /// Friendly spoken form: no trailing .0, at most 2 decimals.
  static func spoken(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
      return String(Int64(value))
    }
    let formatter = NumberFormatter()
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }
}
