//
// VoiceSetup.swift
//
// The guided voice check. You read a few lines in different ways (normal,
// quiet, hyped, serious, a question, fast), then talk freely. Each take
// records loudness, pitch, pace, and your words. At the end it builds your
// voice profile and saves it everywhere.
//

import AVFoundation
import Observation
import Speech

struct VoiceTake: Equatable {
  enum Kind: String {
    case normal, quiet, loud, serious, question, fast, free
  }

  var kind: Kind
  var instruction: String
  var line: String?
}

@Observable
@MainActor
final class VoiceSetupModel {
  static let takes: [VoiceTake] = [
    VoiceTake(kind: .normal, instruction: "Say this in your normal voice", line: "Yo, what's good? I'm just chilling today, nothing crazy."),
    VoiceTake(kind: .quiet, instruction: "Now say it quiet, like someone's sleeping next to you", line: "I'm talking low right now, like I don't want nobody to hear me."),
    VoiceTake(kind: .loud, instruction: "Now hyped up, like something crazy just happened", line: "Bro, that was crazy! Did you see that? No way!"),
    VoiceTake(kind: .serious, instruction: "Now serious, like it matters", line: "Listen, I need you to hear me out on this for real."),
    VoiceTake(kind: .question, instruction: "Ask it like a question", line: "Where you trying to go later, for real?"),
    VoiceTake(kind: .fast, instruction: "Say this fast, like you're in a rush", line: "I gotta hit the store, pick up my cousin, then head right back."),
    VoiceTake(kind: .free, instruction: "Now just talk for about 15 seconds. Anything: your day, what you like, whatever.", line: nil),
  ]

  private(set) var step = 0
  private(set) var isRecording = false
  private(set) var heard = ""
  private(set) var level: Float = -80
  private(set) var done = false
  private(set) var problem: String?
  private(set) var profile: VoiceProfile?

  var current: VoiceTake? { step < Self.takes.count ? Self.takes[step] : nil }

  @ObservationIgnored private let engine = AVAudioEngine()
  @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
  @ObservationIgnored private var task: SFSpeechRecognitionTask?
  @ObservationIgnored private var takeLevels: [Float] = []
  @ObservationIgnored private var takePitches: [Float] = []
  @ObservationIgnored private var takeStart = Date()
  @ObservationIgnored private var results: [VoiceTake.Kind: (levels: [Float], pitches: [Float], words: String, seconds: Double)] = [:]
  @ObservationIgnored private let onSave: (VoiceProfile) -> Void

  init(onSave: @escaping (VoiceProfile) -> Void) {
    self.onSave = onSave
  }

  func record() async {
    guard !isRecording, current != nil else { return }
    problem = nil
    guard await AVAudioApplication.requestRecordPermission() else {
      problem = "Turn on the microphone for Second-Mind in iPhone Settings."
      return
    }
    let auth = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard auth == .authorized, let recognizer, recognizer.isAvailable else {
      problem = "Turn on speech recognition for Second-Mind in iPhone Settings."
      return
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
      try session.setActive(true)
      // Same mic Listen uses: the glasses when they're connected.
      if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
        try session.setPreferredInput(glasses)
      }
    } catch {
      problem = "Couldn't start the mic: \(error.localizedDescription)"
      return
    }

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
    request = req
    heard = ""
    takeLevels = []
    takePitches = []
    takeStart = Date()

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let rate = format.sampleRate
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
      req.append(buffer)
      let level = AudioFeed.level(of: buffer)
      var pitch: Float?
      if let data = buffer.floatChannelData, buffer.frameLength > 0 {
        pitch = PitchDetector.pitch(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)), sampleRate: rate)
      }
      Task { @MainActor [weak self] in self?.sample(level: level, pitch: pitch) }
    }
    task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
      let text = result?.bestTranscription.formattedString
      Task { @MainActor [weak self] in if let text { self?.heard = text } }
    }
    do {
      engine.prepare()
      try engine.start()
      isRecording = true
    } catch {
      problem = "Couldn't start the mic: \(error.localizedDescription)"
      engine.inputNode.removeTap(onBus: 0)
    }
  }

  private func sample(level: Float, pitch: Float?) {
    guard isRecording else { return }
    self.level = level
    // Only count moments when you're actually talking.
    if level > -55 {
      takeLevels.append(level)
      if let pitch { takePitches.append(pitch) }
    }
  }

  /// Ends this take and moves to the next one.
  func finishTake() {
    guard isRecording, let take = current else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    request?.endAudio()
    task?.cancel()
    isRecording = false
    let seconds = max(Date().timeIntervalSince(takeStart), 0.5)

    guard takeLevels.count >= 5, !heard.isEmpty else {
      problem = "Didn't catch that. Tap Record and try again, a little closer to the glasses."
      return
    }
    results[take.kind] = (takeLevels, takePitches, heard, seconds)
    step += 1
    if step >= Self.takes.count { build() }
  }

  /// Skips to doing it again from the start.
  func restart() {
    step = 0
    results = [:]
    done = false
    profile = nil
  }

  private func build() {
    func average(_ values: [Float]) -> Float { values.isEmpty ? -40 : values.reduce(0, +) / Float(values.count) }
    func percentile(_ values: [Float], _ p: Double) -> Float {
      guard !values.isEmpty else { return 0 }
      let sorted = values.sorted()
      return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    let allPitches = results.values.flatMap { $0.pitches }
    let normal = results[.normal]?.levels ?? []
    let quiet = results[.quiet]?.levels ?? []
    let loud = results[.loud]?.levels ?? []
    let totalWords = results.values.reduce(0) { $0 + $1.words.split(separator: " ").count }
    let totalSeconds = results.values.reduce(0) { $0 + $1.seconds }
    let freeTalk = results[.free]?.words ?? ""

    let made = Date()
    let built = VoiceProfile(
      pitch: allPitches.isEmpty ? 140 : percentile(allPitches, 0.5),
      pitchLow: allPitches.isEmpty ? 90 : percentile(allPitches, 0.1),
      pitchHigh: allPitches.isEmpty ? 220 : percentile(allPitches, 0.9),
      quietLevel: average(quiet),
      normalLevel: average(normal),
      loudLevel: average(loud),
      wordsPerSecond: totalSeconds > 0 ? Double(totalWords) / totalSeconds : 2.5,
      words: freeTalk,
      made: made,
      updated: made
    )
    profile = built
    built.save()
    onSave(built)
    done = true
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
