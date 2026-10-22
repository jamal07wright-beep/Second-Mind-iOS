//
// MoodDetector.swift
//
// A rough read on the other person's mood from how they sound and the
// words they use, never how they look. Only chimes when the mood changes,
// and not more than once every 45 seconds. A hint, not a sure thing.
//

import Foundation

enum Mood: String, Codable, Equatable {
  case light
  case neutral
  case tense
  case hurt

  /// 1 chime lighthearted, 2 tense, 3 hurt.
  var chimeCount: Int {
    switch self {
    case .light: return 1
    case .tense: return 2
    case .hurt: return 3
    case .neutral: return 0
    }
  }
}

struct MoodDetector {
  var louderBy: Float = 7
  var fastWords: Double = 3.8
  var cooldown: TimeInterval = 45

  private(set) var baseline: Float?
  private(set) var mood: Mood = .neutral
  private var lastChange: TimeInterval = -.infinity

  static let lightWords: Set<String> = [
    "lol", "haha", "hahaha", "lmao", "funny", "crazy", "bet", "dope", "fire", "love", "nice",
    "awesome", "great", "yay", "joking", "kidding", "facts",
  ]
  static let tenseWords: Set<String> = [
    "stop", "whatever", "seriously", "shut", "annoying", "pissed", "mad", "angry", "wrong",
    "never", "always", "listen", "dude", "bro", "enough", "ridiculous", "hate", "trippin",
    "tripping", "fuck", "fucking", "damn",
  ]
  static let hurtWords: Set<String> = [
    "sorry", "hurt", "sad", "disappointed", "upset", "alone", "cry", "crying", "tired",
    "forgot", "miss", "lonely", "wish", "thought", "fine",
  ]

  /// Scores words: positive leans light, negative leans tense, hurt counted apart.
  static func wordScores(_ text: String) -> (light: Int, tense: Int, hurt: Int) {
    let words = text.lowercased()
      .components(separatedBy: CharacterSet.letters.inverted)
      .filter { !$0.isEmpty }
    var light = 0, tense = 0, hurt = 0
    for word in words {
      if lightWords.contains(word) { light += 1 }
      if tenseWords.contains(word) { tense += 1 }
      if hurtWords.contains(word) { hurt += 1 }
    }
    return (light, tense, hurt)
  }

  /// Feed one finished stretch of their talking. Returns a mood only when it changes.
  mutating func theyFinished(
    averageLevel: Float,
    duration: TimeInterval,
    text: String,
    at time: TimeInterval
  ) -> Mood? {
    let base = baseline ?? averageLevel
    baseline = base * 0.8 + averageLevel * 0.2
    guard duration >= 1.5 else { return nil }

    let words = text.split(separator: " ").count
    let louder = averageLevel - base >= louderBy
    let quieter = base - averageLevel >= louderBy - 2
    let rushing = Double(words) / duration >= fastWords
    let scores = Self.wordScores(text)

    var next: Mood = .neutral
    if (louder || rushing) && scores.tense >= 1 || scores.tense >= 2 || (louder && rushing) {
      next = .tense
    } else if scores.hurt >= 2 || (scores.hurt >= 1 && quieter) {
      next = .hurt
    } else if scores.light >= 1 {
      next = .light
    }

    guard next != mood, next != .neutral, time - lastChange >= cooldown else {
      if next == .neutral { mood = .neutral }
      return nil
    }
    mood = next
    lastChange = time
    return next
  }
}
