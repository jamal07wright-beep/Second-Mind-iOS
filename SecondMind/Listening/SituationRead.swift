//
// SituationRead.swift
//
// Read the room: Claude's running read of the conversation. What you're
// really going for (even if you never said it), what they want, the mood,
// who has the upper hand, and what's likely next. Every Best Reply uses
// it, and Likely Outcomes speaks from it at real turning points.
//

import Foundation

struct SituationRead: Codable, Equatable {
  var userAim: String
  var theirAim: String
  var mood: String
  var upperHand: String
  var nextLikely: String
  var turningPoint: Bool
  var outcomes: [String]
  var lever: String

  enum CodingKeys: String, CodingKey {
    case mood, outcomes, lever
    case userAim = "user_aim"
    case theirAim = "their_aim"
    case upperHand = "upper_hand"
    case nextLikely = "next_likely"
    case turningPoint = "turning_point"
  }

  static var schema: [String: Any] {
    [
      "type": "object",
      "properties": [
        "user_aim": ["type": "string"],
        "their_aim": ["type": "string"],
        "mood": ["type": "string"],
        "upper_hand": ["type": "string"],
        "next_likely": ["type": "string"],
        "turning_point": ["type": "boolean"],
        "outcomes": ["type": "array", "items": ["type": "string"]],
        "lever": ["type": "string"],
      ],
      "required": ["user_aim", "their_aim", "mood", "upper_hand", "next_likely", "turning_point", "outcomes", "lever"],
      "additionalProperties": false,
    ]
  }

  /// Short version that goes into every hint request.
  var brief: String {
    var text = """
      Your read of the situation: the user wants \(userAim). They want \(theirAim). Mood: \(mood). \
      Upper hand: \(upperHand). Likely next: \(nextLikely).
      """
    if !lever.isEmpty { text += " Best honest lever: \(lever)." }
    return text
  }

  /// One line for the screen.
  var summary: String {
    "You want \(userAim). They want \(theirAim). \(mood)."
  }
}
