//
// Chimes.swift
//
// Soft sounds played in the glasses. Timing beeps are plain tones; mood
// chimes are bell-like, so the two never get mixed up.
//
// Beeps:  your turn = one soft tone, hold on = one quick high tick,
//         awkward pause = two tones, talking long = two low tones.
// Chimes: 1 = lighthearted, 2 = getting tense, 3 = they seem hurt.
//

import AVFoundation

enum Chime: Equatable {
  case yourTurn
  case holdOn
  case awkwardPause
  case talkingLong
  case mood(Mood)

  struct Note {
    var frequency: Double
    var seconds: Double
    /// Bells add overtones and ring out; beeps are clean.
    var bell = false
  }

  var notes: [Note] {
    switch self {
    case .yourTurn: return [Note(frequency: 880, seconds: 0.12)]
    case .holdOn: return [Note(frequency: 1_320, seconds: 0.05)]
    case .awkwardPause: return [Note(frequency: 660, seconds: 0.10), Note(frequency: 660, seconds: 0.10)]
    case .talkingLong: return [Note(frequency: 392, seconds: 0.10), Note(frequency: 392, seconds: 0.10)]
    case .mood(let mood):
      let bell = Note(frequency: 1_046, seconds: 0.35, bell: true)
      return [Note](repeating: bell, count: mood.chimeCount)
    }
  }

  static let sampleRate: Double = 44_100
  static let volume: Float = 0.18
  static let gap: Double = 0.09

  var frameCount: Int { samples().count }

  /// Mono float samples with a gentle fade in and out on each note.
  func samples() -> [Float] {
    var out: [Float] = []
    let all = notes
    for (index, note) in all.enumerated() {
      let count = Int(note.seconds * Chime.sampleRate)
      let fade = max(1, Int(0.012 * Chime.sampleRate))
      for i in 0..<count {
        let t = Double(i) / Chime.sampleRate
        var envelope: Float = 1
        if i < fade { envelope = Float(i) / Float(fade) }
        if note.bell {
          envelope *= Float(exp(-4.5 * t))
        } else if i > count - fade {
          envelope = Float(count - i) / Float(fade)
        }
        var wave = sin(2 * .pi * note.frequency * t)
        if note.bell {
          wave = 0.7 * wave + 0.2 * sin(2 * .pi * note.frequency * 2.76 * t) + 0.1 * sin(2 * .pi * note.frequency * 5.4 * t)
        }
        out.append(Float(wave) * Chime.volume * envelope)
      }
      if index < all.count - 1 {
        out.append(contentsOf: [Float](repeating: 0, count: Int(Chime.gap * Chime.sampleRate)))
      }
    }
    return out
  }

  func buffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let data = samples()
    guard
      !data.isEmpty,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)),
      let channels = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(data.count)
    for channel in 0..<Int(format.channelCount) {
      for i in 0..<data.count { channels[channel][i] = data[i] }
    }
    return buffer
  }
}
