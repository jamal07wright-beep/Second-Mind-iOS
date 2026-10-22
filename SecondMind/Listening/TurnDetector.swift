//
// TurnDetector.swift
//
// Works out who is talking from how loud the glasses mic hears it. Your own
// voice is right next to the mic, so it is much louder than the other
// person's. From that it decides when it's your turn, when you've been
// talking a long time, and when you've gone quiet after it was your turn.
//
// Pure logic, no audio APIs, so it can be tested with made-up levels.
//

import Foundation

enum Talker: String, Codable, Equatable {
  case me
  case them
  case nobody
}

enum TurnEvent: Equatable {
  /// They finished talking. Your turn.
  case yourTurn
  /// You've been talking for a long time without a break.
  case talkingLong
  /// It was your turn but you've stayed quiet (awkward pause).
  case stalled
  /// You started talking while they were only pausing.
  case holdOn
  /// One of their stretches of talking finished. Level is the average dB.
  case theyFinished(averageLevel: Float, duration: TimeInterval)
}

struct TurnDetector {
  /// Your voice level, in dB. Set by "Calibrate my voice". Until then a guess.
  var myLevel: Float = -26
  /// Their speech must last this long before a pause counts as your turn.
  var minTheirTalk: TimeInterval = 1.2
  /// Silence this long after they talk means they're done.
  var turnGap: TimeInterval = 0.7
  /// You talking this long (short breaths allowed) triggers a nudge.
  var longTalk: TimeInterval = 45
  /// Quiet this long after your turn started counts as stalled.
  var stallAfter: TimeInterval = 3.0

  private(set) var noiseFloor: Float = -60
  private(set) var current: Talker = .nobody

  private var segmentSpeaker: Talker = .nobody
  private var segmentStart: TimeInterval = 0
  private var segmentLevelSum: Float = 0
  private var segmentFrames = 0
  private var silenceStart: TimeInterval?
  private var myTurnStart: TimeInterval?
  private var warnedLong = false
  private var yourTurnAt: TimeInterval?
  private var stallSent = false

  /// Your saved voice. With it, pitch tells you and others apart, not just loudness.
  var profile: VoiceProfile?

  /// Who this sounds like. The bar for "someone is talking" is low, so quiet
  /// and mumbled voices still count.
  func classify(_ level: Float, pitch: Float? = nil) -> Talker {
    let speechLine = max(noiseFloor + 6, -60)
    guard level > speechLine else { return .nobody }
    if let profile {
      return profile.soundsLikeMe(level: level, pitch: pitch) ? .me : .them
    }
    return level >= myLevel - 6 ? .me : .them
  }

  /// Feed one level reading (about 10 a second). Returns anything worth acting on.
  mutating func feed(level: Float, pitch: Float? = nil, at time: TimeInterval) -> [TurnEvent] {
    trackNoiseFloor(level)
    var events: [TurnEvent] = []
    let who = classify(level, pitch: pitch)
    current = who

    if who == .nobody {
      if silenceStart == nil { silenceStart = time }
      let quiet = time - (silenceStart ?? time)

      if segmentSpeaker == .them, quiet >= turnGap {
        let duration = (silenceStart ?? time) - segmentStart
        if duration >= minTheirTalk {
          events.append(.theyFinished(averageLevel: averageLevel, duration: duration))
          events.append(.yourTurn)
          yourTurnAt = time
          stallSent = false
        }
        endSegment()
      } else if segmentSpeaker == .me, quiet >= 1.5 {
        endSegment()
        myTurnStart = nil
        warnedLong = false
      }

      if let turnAt = yourTurnAt, !stallSent, time - turnAt >= stallAfter {
        events.append(.stalled)
        stallSent = true
      }
      return events
    }

    if who == .me, segmentSpeaker == .them, let quietSince = silenceStart,
      time - quietSince < turnGap, quietSince - segmentStart >= minTheirTalk
    {
      events.append(.holdOn)
    }
    silenceStart = nil

    if who == .me {
      yourTurnAt = nil
      if myTurnStart == nil { myTurnStart = time }
      if let start = myTurnStart, !warnedLong, time - start >= longTalk {
        events.append(.talkingLong)
        warnedLong = true
      }
    } else {
      myTurnStart = nil
      warnedLong = false
      yourTurnAt = nil
    }

    if who != segmentSpeaker {
      endSegment()
      segmentSpeaker = who
      segmentStart = time
    }
    segmentLevelSum += level
    segmentFrames += 1
    return events
  }

  private var averageLevel: Float {
    segmentFrames == 0 ? -60 : segmentLevelSum / Float(segmentFrames)
  }

  private mutating func endSegment() {
    segmentSpeaker = .nobody
    segmentLevelSum = 0
    segmentFrames = 0
  }

  /// Follows the quietest background level: drops fast, rises slowly.
  private mutating func trackNoiseFloor(_ level: Float) {
    if level < noiseFloor {
      noiseFloor = level
    } else {
      noiseFloor += min(0.05, level - noiseFloor)
    }
    noiseFloor = max(noiseFloor, -80)
  }
}
