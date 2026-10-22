//
// CoachPrompts.swift
//
// What Claude is told in Coach mode, per game, and the JSON it replies in.
//

import Foundation

enum CoachGame: String, CaseIterable, Identifiable {
  case fifa = "FIFA / EA FC"
  case deadByDaylight = "Dead by Daylight"
  case work = "Work"
  case anyGame = "Any game"
  var id: String { rawValue }

  var icon: String {
    switch self {
    case .fifa: return "soccerball"
    case .deadByDaylight: return "flashlight.on.fill"
    case .work: return "laptopcomputer"
    case .anyGame: return "gamecontroller.fill"
    }
  }
}

enum CoachPace: String, CaseIterable, Identifiable {
  case fast = "Fast"
  case normal = "Normal"
  var id: String { rawValue }
  /// Seconds between looks.
  var interval: Double { self == .fast ? 2.5 : 5 }
}

/// One look at the screen. Matches `CoachReply.schema`.
struct CoachReply: Codable, Equatable {
  /// What to say now. Empty means stay quiet this time.
  var say: String
  /// Running notes, rewritten every look, so Claude remembers the match.
  var notes: String
  /// "goal_for", "goal_against", "big_moment", or "none".
  var event: String
  /// For goal_for: a 1 to 10 rating with one reason. Otherwise empty.
  var rating: String

  static var schema: [String: Any] {
    [
      "type": "object",
      "properties": [
        "say": ["type": "string"],
        "notes": ["type": "string"],
        "event": ["type": "string", "enum": ["none", "goal_for", "goal_against", "big_moment"]],
        "rating": ["type": "string"],
      ],
      "required": ["say", "notes", "event", "rating"],
      "additionalProperties": false,
    ]
  }
}

enum CoachPrompts {
  static func system(game: CoachGame, mode: FeatureMode, aboutMe: String) -> String {
    let eagerness = mode == .always
      ? "Give a call on every look, even a short one like \"Good, keep it up.\""
      : "Only talk when it's useful right now; otherwise leave say empty. Never repeat a call you just made."
    var text = """
      You are Second-Mind in Coach mode. The user wears smart glasses whose camera is pointed \
      at their screen; you get a photo of it every few seconds. Your words are spoken into \
      their ear while they play or work, so "say" must be under 12 words, plain, no dashes, \
      and instantly useful. \(eagerness)

      Keep "notes" as your running analysis (under 120 words): rewrite it each time with what \
      you've learned so far. If the picture is blurry, dark, or not the screen, leave say empty \
      and keep your notes.

      \(guide(game))
      """
    let about = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
    if !about.isEmpty { text += "\n\nAbout the user, in their words:\n\(about)" }
    return text
  }

  static func guide(_ game: CoachGame) -> String {
    switch game {
    case .fifa:
      return """
        Game: FIFA / EA Sports FC. Act like a real football manager on the touchline. The user's \
        team plays a 4-3-3 (GK, LB, CB, CB, RB, CDM, CM, CM, LW, ST, RW); use that when guessing \
        positions. Track: what's working for the user, where they're strong and weak on the \
        pitch, the opponent's weaknesses, and where the opponent is strongest. Give specific, \
        tactical calls like "Their left back pushes up, hit the space with your RW" or "Stop \
        going through the middle, they're packed there." When the score changes or a GOAL \
        replay shows: set event to goal_for or goal_against. For goal_for, rate the goal 1 to \
        10 in rating with one reason (build up, finish, decision). For goal_against, say what \
        went wrong in say.
        """
    case .deadByDaylight:
      return """
        Game: Dead by Daylight. First work out if the user is a survivor or the killer. As \
        survivor: generator progress, where the killer probably is, terror radius and chase \
        cues, loops and pallets, when to heal, hide, or rescue, hook states, and the exit \
        gates. As killer: which survivor is injured or weakest, gen pressure, when to drop a \
        chase, hook and patrol choices. Calls like "Pallet on your left" or "Two gens close \
        together, defend them." Use big_moment for downs, hooks, saves, and escapes.
        """
    case .work:
      return """
        Mode: work. Look at what's on their screen and help them work faster and better: catch \
        mistakes, typos, or bugs, suggest the next step, or point out something they missed. \
        If they look stuck, give the one tip that unblocks them. Calls can be up to 20 words.
        """
    case .anyGame:
      return """
        Game: work out which game it is from the screen. Coach like an expert player: what to \
        do right now, what's working, the opponent's weak spots, and mistakes to stop making. \
        Use big_moment for wins, losses, and turning points.
        """
    }
  }

  static func look(notes: String, recentCalls: [String]) -> String {
    let calls = recentCalls.isEmpty ? "none yet" : recentCalls.joined(separator: " | ")
    return """
      New look at the screen. Your notes so far: \(notes.isEmpty ? "none yet" : notes)
      Your last calls: \(calls)
      Reply in JSON.
      """
  }

  static func report(game: CoachGame) -> String {
    """
    Write an honest coach's report on this \(game.rawValue) session from your notes and calls, \
    like a real manager talking to their player after the match. Plain words, short sentences, \
    no dashes. Cover: what worked, what didn't, the opponent's strengths and weak spots, \
    ratings of any goals or big moments, and the top three things to work on next time. \
    Under 250 words.
    """
  }
}
