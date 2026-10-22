//
// HumanVoice.swift
//
// The voice Second-Mind talks with in Listen mode. With an ElevenLabs key
// it uses a real human-sounding voice; without one it uses the best voice
// installed on the iPhone (Premium, then Enhanced).
//

import AVFoundation
import Foundation

/// What we need to rank an Apple voice. Separate from AVSpeechSynthesisVoice so it can be tested.
struct VoiceInfo: Equatable, Identifiable {
  enum Quality: Int, Comparable {
    case standard = 1
    case enhanced = 2
    case premium = 3
    static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
  }

  var id: String
  var name: String
  var language: String
  var quality: Quality
  var isNovelty: Bool

  var label: String {
    switch quality {
    case .premium: return "\(name) (Premium)"
    case .enhanced: return "\(name) (Enhanced)"
    case .standard: return name
    }
  }
}

enum VoicePicker {
  /// English, no novelty voices, best quality first, US English first.
  static func ranked(_ voices: [VoiceInfo]) -> [VoiceInfo] {
    voices
      .filter { $0.language.hasPrefix("en") && !$0.isNovelty }
      .sorted { a, b in
        if a.quality != b.quality { return a.quality > b.quality }
        let aUS = a.language == "en-US"
        let bUS = b.language == "en-US"
        if aUS != bUS { return aUS }
        return a.name < b.name
      }
  }

  static func choose(_ voices: [VoiceInfo], preferred: String?) -> VoiceInfo? {
    let options = ranked(voices)
    if let preferred, let match = options.first(where: { $0.id == preferred }) {
      return match
    }
    return options.first
  }

  static func installed() -> [VoiceInfo] {
    AVSpeechSynthesisVoice.speechVoices().map { voice in
      let quality: VoiceInfo.Quality
      switch voice.quality {
      case .premium: quality = .premium
      case .enhanced: quality = .enhanced
      default: quality = .standard
      }
      return VoiceInfo(
        id: voice.identifier,
        name: voice.name,
        language: voice.language,
        quality: quality,
        isNovelty: voice.voiceTraits.contains(.isNoveltyVoice)
      )
    }
  }
}

/// ElevenLabs text to speech, returned as MP3 audio.
struct ElevenLabsClient {
  var apiKey: String
  var voiceID: String
  var model = "eleven_flash_v2_5"
  var session: URLSession = .shared

  /// A warm, natural premade voice. Can be changed in Settings.
  static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"

  func makeRequest(text: String) throws -> URLRequest {
    var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!
    components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("audio/mpeg", forHTTPHeaderField: "accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "text": text,
      "model_id": model,
      "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "style": 0.2, "use_speaker_boost": true],
    ])
    return request
  }

  func audio(for text: String) async throws -> Data {
    let (data, response) = try await session.data(for: makeRequest(text: text))
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      throw NSError(
        domain: "ElevenLabs",
        code: status,
        userInfo: [NSLocalizedDescriptionKey: "Voice service error \(status)"]
      )
    }
    return data
  }
}

/// Speaks and tells you when it's done. Never changes the audio session;
/// Listen mode sets that up around each line.
@MainActor
final class HumanVoice: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var player: AVAudioPlayer?
  private var finished: CheckedContinuation<Void, Never>?
  private let settings: AISettings

  init(settings: AISettings) {
    self.settings = settings
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }

  private(set) var isSpeaking = false
  /// Why the ElevenLabs voice didn't play last time, if it didn't.
  private(set) var lastError: String?

  /// Audio ready to play: the human voice if it downloaded, otherwise the text
  /// for the iPhone voice.
  enum Prepared {
    case audio(Data, text: String)
    case phone(String)
  }

  /// Gets the voice ready before anything else happens, so the glasses audio
  /// switch never cuts off the first words.
  func prepare(_ text: String) async -> Prepared {
    lastError = nil
    guard let key = settings.elevenLabsKey else { return .phone(text) }
    do {
      let data = try await ElevenLabsClient(apiKey: key, voiceID: settings.elevenLabsVoiceID).audio(for: text)
      return .audio(data, text: text)
    } catch {
      lastError = "ElevenLabs voice didn't work (\(error.localizedDescription)). Used the iPhone voice."
      return .phone(text)
    }
  }

  /// Speaks the text and returns when it's finished (or stopped).
  func speak(_ text: String, rate: Float = 0.5) async {
    await play(prepare(text), rate: rate)
  }

  func play(_ prepared: Prepared, rate: Float = 0.5) async {
    stop()
    isSpeaking = true
    defer { isSpeaking = false }

    let text: String
    switch prepared {
    case .audio(let data, let words):
      if let audio = try? AVAudioPlayer(data: data) {
        audio.delegate = self
        audio.volume = 1.0
        player = audio
        await withCheckedContinuation { continuation in
          finished = continuation
          if !audio.play() { finish() }
        }
        player = nil
        return
      }
      lastError = "Couldn't play the downloaded voice. Used the iPhone voice."
      text = words
    case .phone(let words):
      text = words
    }

    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = rate
    if let pick = VoicePicker.choose(VoicePicker.installed(), preferred: settings.appleVoiceID) {
      utterance.voice = AVSpeechSynthesisVoice(identifier: pick.id)
    }
    await withCheckedContinuation { continuation in
      finished = continuation
      synthesizer.speak(utterance)
    }
  }

  func stop() {
    player?.stop()
    player = nil
    if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    finish()
  }

  private func finish() {
    let continuation = finished
    finished = nil
    continuation?.resume()
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.finish() }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.finish() }
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in self.finish() }
  }
}
