//
// Speaker.swift
//
// Says text out loud. With the glasses connected, iPhone sends the sound to
// the glasses speakers like any Bluetooth headphones.
//

import AVFoundation

@MainActor
protocol Speaker: AnyObject {
  var isSpeaking: Bool { get }
  func speak(_ text: String, rate: Float)
  func stop()
}

@MainActor
final class SystemSpeaker: Speaker {
  private let synthesizer = AVSpeechSynthesizer()

  var isSpeaking: Bool { synthesizer.isSpeaking }

  func speak(_ text: String, rate: Float) {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    try? session.setActive(true)

    synthesizer.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = rate
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }
}
