//
// VoiceProfile.swift
//
// What Second-Mind knows about your voice: pitch, loudness, pace, and the
// words you use. Made once in voice setup, kept forever, and it keeps
// learning your words from your conversations.
//
// Saved three ways so it never has to be redone: the iPhone keychain
// (survives updates and reinstalls), the app's own folder, and a "My Voice"
// note in your Obsidian vault.
//

import Foundation

struct VoiceProfile: Codable, Equatable {
  /// Middle of your speaking pitch, in Hz.
  var pitch: Float
  /// Your usual pitch range (low and high), in Hz.
  var pitchLow: Float
  var pitchHigh: Float
  /// Loudness in the glasses mic, in dB, for quiet, normal, and loud speech.
  var quietLevel: Float
  var normalLevel: Float
  var loudLevel: Float
  /// How fast you talk.
  var wordsPerSecond: Double
  /// Your own words and phrases, newest last. Capped so it stays small.
  var words: String
  var made: Date
  var updated: Date

  static let wordLimit = 3_000

  /// Adds things you said, keeping only the newest part.
  mutating func learn(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    words = String((words + " " + clean).suffix(Self.wordLimit)).trimmingCharacters(in: .whitespaces)
    updated = Date()
  }

  /// Does this sound like you? Pitch must fit your range (when we have a
  /// pitch), and loudness must be at least near your quiet voice.
  func soundsLikeMe(level: Float, pitch heard: Float?) -> Bool {
    guard level >= quietLevel - 4 else { return false }
    guard let heard else { return level >= normalLevel - 3 }
    let low = min(pitchLow, pitch) * 0.88
    let high = max(pitchHigh, pitch) * 1.12
    return heard >= low && heard <= high
  }

  /// A plain description for Claude, so replies match how you talk.
  var styleNote: String {
    let pace: String
    switch wordsPerSecond {
    case ..<2.2: pace = "slow and steady"
    case ..<3.2: pace = "a normal pace"
    default: pace = "fast"
    }
    let sample = words.split(separator: " ").suffix(150).joined(separator: " ")
    return """
      How the user talks: \(pace) (about \(String(format: "%.1f", wordsPerSecond)) words a second). \
      Match their rhythm and keep hints short enough to say at that pace. Their own words, from \
      things they've said (copy their vocabulary and slang, not the content): "\(sample)"
      """
  }

  // MARK: - Saving

  private static let keychainAccount = "voiceProfile"

  private static var fileURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("VoiceProfile.json")
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  func json() -> String? {
    guard let data = try? Self.encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func from(json: String) -> VoiceProfile? {
    try? decoder.decode(VoiceProfile.self, from: Data(json.utf8))
  }

  /// Saves to the keychain and the app folder.
  func save() {
    guard let text = json() else { return }
    _ = Keychain.save(text, as: Self.keychainAccount)
    try? Data(text.utf8).write(to: Self.fileURL, options: .atomic)
  }

  /// Loads from the keychain first (it survives reinstalls), then the app folder.
  static func load() -> VoiceProfile? {
    if let text = Keychain.read(keychainAccount), let profile = from(json: text) { return profile }
    if let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) {
      return from(json: text)
    }
    return nil
  }

  /// The "My Voice" note for Obsidian, with the data tucked in so it can be restored.
  func obsidianNote() -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return """
      ---
      tags: [second-mind, me]
      ---
      # My Voice

      What Second-Mind knows about how I sound and talk. Made \(formatter.string(from: made)), \
      updated \(formatter.string(from: updated)).

      - Pitch: about \(Int(pitch)) Hz (range \(Int(pitchLow)) to \(Int(pitchHigh)))
      - Loudness in the glasses mic: quiet \(Int(quietLevel)) dB, normal \(Int(normalLevel)) dB, loud \(Int(loudLevel)) dB
      - Pace: \(String(format: "%.1f", wordsPerSecond)) words a second

      ## Words I use
      \(words.split(separator: " ").suffix(300).joined(separator: " "))

      Back to [[Second-Mind Home]]

      ```second-mind-voice
      \(json() ?? "")
      ```
      """
  }

  /// Reads the profile back out of a "My Voice" note.
  static func from(note: String) -> VoiceProfile? {
    guard
      let start = note.range(of: "```second-mind-voice\n"),
      let end = note.range(of: "\n```", range: start.upperBound..<note.endIndex)
    else { return nil }
    return from(json: String(note[start.upperBound..<end.lowerBound]))
  }
}

/// Finds the pitch of a voice in a short piece of audio.
enum PitchDetector {
  /// Pitch in Hz, or nil if it isn't clearly a voice. Looks for 70 to 400 Hz.
  static func pitch(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Float? {
    let count = samples.count
    let minLag = max(2, Int(sampleRate / 400))
    let maxLag = min(count / 2, Int(sampleRate / 70))
    guard maxLag > minLag else { return nil }

    var energy: Float = 0
    for i in 0..<count { energy += samples[i] * samples[i] }
    guard energy > 1e-6 else { return nil }

    var bestLag = 0
    var best: Float = 0
    for lag in minLag...maxLag {
      var sum: Float = 0
      var norm: Float = 0
      let n = count - lag
      for i in 0..<n {
        sum += samples[i] * samples[i + lag]
        norm += samples[i + lag] * samples[i + lag]
      }
      let score = sum / (energy * norm).squareRoot().clamped(min: 1e-9)
      if score > best {
        best = score
        bestLag = lag
      }
    }
    guard best > 0.45, bestLag > 0 else { return nil }
    return Float(sampleRate) / Float(bestLag)
  }

  static func pitch(_ samples: [Float], sampleRate: Double) -> Float? {
    samples.withUnsafeBufferPointer { pitch($0, sampleRate: sampleRate) }
  }
}

extension Float {
  func clamped(min low: Float) -> Float { Swift.max(self, low) }
}
