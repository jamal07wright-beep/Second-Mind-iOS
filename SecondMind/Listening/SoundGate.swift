//
// SoundGate.swift
//
// Tells people talking apart from music, singing, nature, and other noise,
// using Apple's built-in sound classifier on the phone (free, private).
// Listen mode only treats sound as conversation when it's really speech.
//

import AVFoundation
import SoundAnalysis

/// What the classifier thinks is in the last second of sound, 0 to 1.
struct SoundScores: Equatable {
  var speech: Double = 0
  var music: Double = 0
  var noise: Double = 0

  /// Is someone talking, and not just lyrics or background?
  var isSpeech: Bool {
    speech >= 0.35 && speech >= music * 0.8
  }

  var isMusic: Bool { music >= 0.5 && music > speech }

  /// Sorts classifier labels into speech, music, and noise.
  static func from(_ labels: [(String, Double)]) -> SoundScores {
    var scores = SoundScores()
    for (raw, confidence) in labels {
      let label = raw.lowercased()
      if speechWords.contains(where: { label.contains($0) }) {
        scores.speech = max(scores.speech, confidence)
      } else if musicWords.contains(where: { label.contains($0) }) {
        scores.music = max(scores.music, confidence)
      } else {
        scores.noise = max(scores.noise, confidence)
      }
    }
    return scores
  }

  static let speechWords = ["speech", "conversation", "whisper", "shout", "yell", "narration", "talk", "babble"]
  static let musicWords = [
    "music", "singing", "song", "rap", "choir", "guitar", "piano", "drum", "bass", "instrument",
    "orchestra", "beat", "hip_hop", "hip hop", "synth", "violin", "trumpet",
  ]
}

/// Runs the classifier on mic audio, off the audio thread.
final class SoundGate: NSObject, SNResultsObserving, @unchecked Sendable {
  private let analyzer: SNAudioStreamAnalyzer
  private let queue = DispatchQueue(label: "SecondMind.SoundGate")
  private var position: AVAudioFramePosition = 0
  private let lock = NSLock()
  private var _scores = SoundScores()

  /// The newest scores. Starts as "speech" so nothing is lost before the first result.
  var scores: SoundScores {
    lock.lock()
    defer { lock.unlock() }
    return _scores
  }

  init?(format: AVAudioFormat) {
    analyzer = SNAudioStreamAnalyzer(format: format)
    super.init()
    _scores = SoundScores(speech: 1, music: 0, noise: 0)
    guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
    request.windowDuration = CMTime(seconds: 0.975, preferredTimescale: 48_000)
    request.overlapFactor = 0.5
    guard (try? analyzer.add(request, withObserver: self)) != nil else { return nil }
  }

  func analyze(_ buffer: AVAudioPCMBuffer) {
    queue.async { [self] in
      analyzer.analyze(buffer, atAudioFramePosition: position)
      position += AVAudioFramePosition(buffer.frameLength)
    }
  }

  func request(_ request: SNRequest, didProduce result: SNResult) {
    guard let result = result as? SNClassificationResult else { return }
    let labels = result.classifications.prefix(12).map { ($0.identifier, $0.confidence) }
    let scores = SoundScores.from(Array(labels))
    lock.lock()
    _scores = scores
    lock.unlock()
  }

  func request(_ request: SNRequest, didFailWithError error: Error) {}
  func requestDidComplete(_ request: SNRequest) {}
}
