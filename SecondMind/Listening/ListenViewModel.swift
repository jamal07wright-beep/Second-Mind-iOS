//
// ListenViewModel.swift
//
// Stage 2, the always-on part. Flip it on, lock the phone, and it runs by
// itself: the glasses mic listens (camera off, so no light), Apple's
// on-device speech recognition writes the transcript, and the switches you
// turned on decide what happens:
//
//   Social Push   beeps for your turn, hold on, and awkward pauses; mood chimes
//   Debate        a reply hint, ready when they stop talking
//   Fact Check    a short correction, only when something's wrong
//   Consistency   a quiet note when something doesn't match
//   Translate     the English, after each of their sentences
//   Directions    "Directions to X?" with a Yes button, then walking steps
//   Math          the real calculator's answer, explained if you want
//
// Conversations are saved on the phone for Reflect and the nightly graph.
//

import AVFoundation
import Observation
import Speech
import UIKit

@Observable
@MainActor
final class ListenViewModel {
  // MARK: - What the screen shows

  private(set) var isOn = false
  private(set) var status = "Off"
  private(set) var usingGlassesMic = false
  private(set) var talker: Talker = .nobody
  private(set) var partial = ""
  private(set) var conversation: Conversation?
  private(set) var lastSaid: String?
  private(set) var isCalibrating = false

  var showError = false
  var errorMessage = ""

  // Social Push switches.
  var turnBeeps: Bool { didSet { save(turnBeeps, "listen.turnBeeps") } }
  var moodChimes: Bool { didSet { save(moodChimes, "listen.mood") } }
  var longTalkNudge: Bool { didSet { save(longTalkNudge, "listen.longTalk") } }
  var helpWhenStuck: Bool { didSet { save(helpWhenStuck, "listen.claude") } }
  /// Pause the mic for a moment while talking, so the voice plays in full quality.
  var clearVoice: Bool { didSet { save(clearVoice, "listen.clearVoice") } }
  var speechRate: Float = 0.5

  let navigator = Navigator()

  // MARK: - Private

  @ObservationIgnored private let ai: AISettings
  @ObservationIgnored private let voice: HumanVoice
  @ObservationIgnored private let store = ConversationStore()
  @ObservationIgnored private let engine = AVAudioEngine()
  @ObservationIgnored private let player = AVAudioPlayerNode()
  @ObservationIgnored private let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: Chime.sampleRate, channels: 1)!
  @ObservationIgnored private var recognizer: SFSpeechRecognizer?
  @ObservationIgnored private let feed = AudioFeed()
  @ObservationIgnored private var task: SFSpeechRecognitionTask?
  @ObservationIgnored private var detector = TurnDetector()
  @ObservationIgnored private var mood = MoodDetector()
  @ObservationIgnored private var startedAt = Date()
  @ObservationIgnored private var lastSpeechAt: TimeInterval = 0
  @ObservationIgnored private var utteranceStartedAt: TimeInterval?
  @ObservationIgnored private var meFrames = 0
  @ObservationIgnored private var themFrames = 0
  @ObservationIgnored private var calibrationLevels: [Float] = []
  @ObservationIgnored private var playerAttached = false
  @ObservationIgnored private var micPaused = false

  // Speaking queue.
  @ObservationIgnored private var toSay: [String] = []
  @ObservationIgnored private var isSaying = false

  // Claude pacing, so calls never pile up.
  @ObservationIgnored private var lastHelpAt: TimeInterval = -.infinity
  @ObservationIgnored private var lastFactCheckAt: TimeInterval = -.infinity
  @ObservationIgnored private var lastConsistencyAt: TimeInterval = -.infinity
  @ObservationIgnored private var linesAtLastConsistency = 0
  @ObservationIgnored private var busy: Set<String> = []
  @ObservationIgnored private var pendingHint: (text: String, at: TimeInterval)?
  // Debate prediction: hints built while they're still talking.
  @ObservationIgnored private var predictedWords = 0
  @ObservationIgnored private var lastPredictAt: TimeInterval = -.infinity
  @ObservationIgnored private var lastYourTurnAt: TimeInterval = -.infinity

  init(ai: AISettings) {
    self.ai = ai
    self.voice = HumanVoice(settings: ai)
    let d = UserDefaults.standard
    func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
    turnBeeps = flag("listen.turnBeeps", true)
    moodChimes = flag("listen.mood", true)
    longTalkNudge = flag("listen.longTalk", false)
    helpWhenStuck = flag("listen.claude", true)
    clearVoice = flag("listen.clearVoice", true)
    if d.object(forKey: "listen.myLevel") != nil {
      detector.myLevel = d.float(forKey: "listen.myLevel")
    }
    navigator.say = { [weak self] text in self?.say(text) }
  }

  var isCalibrated: Bool { UserDefaults.standard.object(forKey: "listen.myLevel") != nil }

  // MARK: - On / off

  func start() async {
    guard !isOn else { return }
    guard await askPermissions() else { return }
    let locale = ai.translate ? ai.translateFrom : "en-US"
    recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
    guard recognizer?.isAvailable == true else {
      fail("Speech recognition for \(locale) isn't available on this phone.")
      return
    }
    do {
      try configureAudio()
      try startEngine()
    } catch {
      fail("Couldn't start the microphone: \(error.localizedDescription)")
      teardownAudio()
      return
    }
    navigator.requestPermissions()
    isOn = true
    startedAt = Date()
    conversation = Conversation(started: startedAt)
    var fresh = TurnDetector()
    fresh.myLevel = detector.myLevel
    detector = fresh
    mood = MoodDetector()
    pendingHint = nil
    UIApplication.shared.isIdleTimerDisabled = true
    status = usingGlassesMic
      ? "On. Listening through your glasses. You can lock your phone."
      : "On, but using the phone mic. Connect your glasses in Bluetooth."
    startRecognition()
  }

  func stop() {
    guard isOn else { return }
    isOn = false
    isCalibrating = false
    toSay = []
    voice.stop()
    finishUtterance()
    task?.cancel()
    task = nil
    teardownAudio()
    UIApplication.shared.isIdleTimerDisabled = false
    if var convo = conversation, !convo.lines.isEmpty {
      convo.ended = Date()
      try? store.save(convo)
    }
    conversation = nil
    partial = ""
    talker = .nobody
    status = "Off. Saved for tonight's notes."
  }

  // MARK: - Calibrate

  /// Say a sentence or two. Learns how loud your voice is in the glasses mic.
  func calibrate() {
    guard isOn, !isCalibrating else { return }
    isCalibrating = true
    calibrationLevels = []
    status = "Say a sentence or two in your normal voice…"
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(4))
      self?.finishCalibration()
    }
  }

  private func finishCalibration() {
    guard isCalibrating else { return }
    isCalibrating = false
    let loud = calibrationLevels.sorted().suffix(max(calibrationLevels.count / 2, 1))
    guard calibrationLevels.count >= 10, !loud.isEmpty else {
      status = "Didn't hear you. Try again."
      return
    }
    let level = loud.reduce(0, +) / Float(loud.count)
    detector.myLevel = level
    UserDefaults.standard.set(level, forKey: "listen.myLevel")
    status = "Got your voice."
  }

  // MARK: - Speaking

  /// Queues a line to say in the glasses.
  func say(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != Prompts.quiet else { return }
    lastSaid = clean
    toSay.append(clean)
    guard !isSaying else { return }
    Task { await drainSpeech() }
  }

  private func drainSpeech() async {
    isSaying = true
    defer { isSaying = false }
    while !toSay.isEmpty {
      let line = toSay.removeFirst()
      feed.muted = true
      let paused = isOn && clearVoice
      if paused { pauseMicForVoice() }
      if !isOn {
        // Testing the voice from Settings: plain playback, even on silent mode.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
      }
      await voice.speak(line, rate: speechRate)
      if paused { resumeMic() }
      feed.muted = false
    }
  }

  private func pauseMicForVoice() {
    finishUtterance()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    micPaused = true
    // Playback only: the glasses switch to full-quality audio.
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    try? session.setActive(true)
  }

  private func resumeMic() {
    guard micPaused, isOn else { return }
    micPaused = false
    do {
      try configureAudio()
      try startEngine()
      if task == nil { startRecognition() }
    } catch {
      fail("The mic didn't come back: \(error.localizedDescription)")
    }
  }

  // MARK: - Audio setup

  private func askPermissions() async -> Bool {
    guard await AVAudioApplication.requestRecordPermission() else {
      fail("Microphone is off for Second-Mind. Turn it on in Settings > Second-Mind.")
      return false
    }
    let speech = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard speech == .authorized else {
      fail("Speech recognition is off for Second-Mind. Turn it on in Settings > Second-Mind.")
      return false
    }
    return true
  }

  private func configureAudio() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
    try session.setActive(true)
    // Use the glasses mic, never the phone's, when the glasses are connected.
    if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
      try session.setPreferredInput(glasses)
    }
    usingGlassesMic = session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
  }

  private func startEngine() throws {
    if !playerAttached {
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: chimeFormat)
      playerAttached = true
    }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let feed = self.feed
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
      let level = AudioFeed.level(of: buffer)
      feed.append(buffer)
      Task { @MainActor [weak self] in self?.heard(level: level) }
    }
    engine.prepare()
    try engine.start()
  }

  private func teardownAudio() {
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
    feed.set(nil)
    micPaused = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // MARK: - Speech to text

  private func startRecognition() {
    guard isOn, let recognizer else { return }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
    if recognizer.supportsOnDeviceRecognition {
      // Private and free: the words never leave the phone.
      request.requiresOnDeviceRecognition = true
    }
    feed.set(request)
    meFrames = 0
    themFrames = 0
    utteranceStartedAt = nil
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let done = (result?.isFinal ?? false) || error != nil
      Task { @MainActor [weak self] in self?.recognized(text, done: done) }
    }
  }

  private func recognized(_ text: String?, done: Bool) {
    guard isOn else { return }
    if let text {
      partial = text
      predictReply()
    }
    guard done else { return }
    predictedWords = 0
    let line = partial
    partial = ""
    task = nil
    commit(line)
    // Start a fresh request for the next thing anyone says.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard let self, self.isOn, !self.micPaused, self.task == nil else { return }
      self.startRecognition()
    }
  }

  /// Ends the current utterance so it becomes a saved line.
  private func finishUtterance() {
    feed.request?.endAudio()
    feed.set(nil)
  }

  private func commit(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, conversation != nil else { return }
    let who: Talker = meFrames >= themFrames ? .me : .them
    meFrames = 0
    themFrames = 0
    conversation?.lines.append(ConversationLine(time: Date(), speaker: who, text: clean))
    autosave()
    react(to: clean, from: who)
  }

  /// Keeps a copy on disk, so nothing is lost if the app is closed mid-talk.
  private func autosave() {
    guard let convo = conversation, convo.lines.count % 5 == 0 else { return }
    try? store.save(convo)
  }

  // MARK: - Every level reading

  private func heard(level: Float) {
    guard isOn, !micPaused else { return }
    let now = Date().timeIntervalSince(startedAt)

    // Don't treat our own voice or chimes as people talking.
    if voice.isSpeaking || player.isPlaying {
      feed.muted = true
      return
    }
    if !isSaying { feed.muted = false }

    if isCalibrating, level > detector.noiseFloor + 10 {
      calibrationLevels.append(level)
    }

    let events = detector.feed(level: level, at: now)
    talker = detector.current

    switch detector.current {
    case .me:
      meFrames += 1
      lastSpeechAt = now
      if utteranceStartedAt == nil { utteranceStartedAt = now }
    case .them:
      themFrames += 1
      lastSpeechAt = now
      if utteranceStartedAt == nil { utteranceStartedAt = now }
    case .nobody:
      break
    }

    // A pause, or a very long stretch, closes the current line.
    if let started = utteranceStartedAt, feed.request != nil,
      now - lastSpeechAt >= 0.9 || now - started >= 50
    {
      finishUtterance()
      utteranceStartedAt = nil
    }

    for event in events { handle(event, at: now) }
  }

  private func handle(_ event: TurnEvent, at now: TimeInterval) {
    guard !isCalibrating else { return }
    switch event {
    case .yourTurn:
      lastYourTurnAt = now
      if turnBeeps { play(.yourTurn) }
      if let hint = pendingHint, now - hint.at < 25 {
        pendingHint = nil
        say(hint.text)
      }
    case .holdOn:
      if turnBeeps { play(.holdOn) }
    case .talkingLong:
      if longTalkNudge { play(.talkingLong) }
    case .theyFinished(let average, let duration):
      if moodChimes,
        let change = mood.theyFinished(averageLevel: average, duration: duration, text: lastThemText, at: now)
      {
        play(.mood(change))
      }
    case .stalled:
      if turnBeeps { play(.awkwardPause) }
      if helpWhenStuck, ai.hasKey, now - lastHelpAt >= 20 {
        lastHelpAt = now
        run("stuck") {
          try await self.ask(Prompts.stuck + "\n\n" + Prompts.styleGuide(self.ai.replyStyle), recent: 14)
        }
      }
    }
  }

  private var lastThemText: String {
    conversation?.lines.last(where: { $0.speaker == .them })?.text ?? partial
  }

  private func play(_ chime: Chime) {
    guard !micPaused, engine.isRunning, let buffer = chime.buffer(format: chimeFormat) else { return }
    player.scheduleBuffer(buffer, completionHandler: nil)
    if !player.isPlaying { player.play() }
  }

  // MARK: - Stage 2 reactions to each new line

  private func react(to line: String, from who: Talker) {
    guard ai.hasKey else { return }
    let now = Date().timeIntervalSince(startedAt)
    let lines = conversation?.lines.count ?? 0

    if ai.translate, who == .them {
      run("translate") {
        let english = try await self.ai.client.ask(
          system: self.system(Prompts.translate(from: self.languageName)),
          user: "Newest line: \(line)",
          maxTokens: 1_000
        )
        self.say(english)
      }
    }

    if ai.factCheck, Self.hasClaim(line), now - lastFactCheckAt >= 20 {
      lastFactCheckAt = now
      run("fact") {
        let fix = try await self.ai.client.ask(
          system: self.system(Prompts.factCheck),
          user: "Conversation so far:\n\(self.conversation?.recent(8) ?? line)",
          maxTokens: 4_000,
          webSearch: true
        )
        guard fix != Prompts.quiet else { return }
        self.conversation?.notes.append("Fact check: \(fix)")
        self.say(fix)
      }
    }

    if ai.consistency, lines >= 6, lines - linesAtLastConsistency >= 4, now - lastConsistencyAt >= 45 {
      lastConsistencyAt = now
      linesAtLastConsistency = lines
      run("consistency") {
        let note = try await self.ai.client.ask(
          system: self.system(Prompts.consistency),
          user: "Whole conversation:\n\(self.conversation?.transcript ?? line)",
          effort: "medium"
        )
        guard note != Prompts.quiet else { return }
        self.conversation?.notes.append("Mismatch: \(note)")
        self.say(note)
      }
    }

    if ai.planDetection, Self.mentionsPlace(line), navigator.pendingPlace == nil, !navigator.isNavigating {
      run("plans") { try await self.checkPlan(line) }
    }

    if ai.math, MathEngine.looksLikeMath(line) {
      run("math") { try await self.solve(line) }
    }
  }

  /// Debate: builds the reply while they're still talking, from the words
  /// heard so far, and refreshes it every few new words. When they stop,
  /// the newest hint is already waiting.
  private func predictReply() {
    guard ai.debate, ai.hasKey, themFrames > meFrames else { return }
    let now = Date().timeIntervalSince(startedAt)
    let words = partial.split(separator: " ").count
    let enoughNew = words - predictedWords >= 6
    let stale = words > predictedWords && now - lastPredictAt >= 3
    guard words >= 6, enoughNew || stale else { return }
    predictedWords = words
    lastPredictAt = now
    let heard = partial
    run("debate") {
      let hint = try await self.ai.client.ask(
        system: self.system(Prompts.bestReply(self.ai.replyStyle)),
        user: "Conversation so far:\n\(self.conversation?.recent(12) ?? "")\nThem (still talking): \(heard)"
      )
      guard hint != Prompts.quiet else { return }
      let ready = Date().timeIntervalSince(self.startedAt)
      if self.detector.current == .nobody, ready - self.lastYourTurnAt < 4 {
        // They already stopped and it's your turn: say it right away.
        self.pendingHint = nil
        self.say(hint)
      } else {
        self.pendingHint = (hint, ready)
      }
    }
  }

  private func checkPlan(_ line: String) async throws {
    let schema: [String: Any] = [
      "type": "object",
      "properties": [
        "kind": ["type": "string", "enum": ["plan", "mention", "none"]],
        "place": ["type": "string"],
      ],
      "required": ["kind", "place"],
      "additionalProperties": false,
    ]
    let reply = try await ai.client.ask(
      system: system(Prompts.plans),
      user: "Recent lines:\n\(conversation?.recent(6) ?? line)",
      schema: schema
    )
    guard
      let json = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: String],
      let place = json["place"]?.trimmingCharacters(in: .whitespaces), !place.isEmpty
    else { return }
    switch json["kind"] {
    case "plan":
      navigator.ask(place: place)
    case "mention":
      if !ai.savedPlaces.contains(place) { ai.savedPlaces.append(place) }
    default:
      break
    }
  }

  private func solve(_ line: String) async throws {
    let schema: [String: Any] = [
      "type": "object",
      "properties": ["expression": ["type": "string"]],
      "required": ["expression"],
      "additionalProperties": false,
    ]
    let reply = try await ai.client.ask(
      system: system(Prompts.mathToExpression),
      user: "Newest line: \(line)",
      schema: schema
    )
    guard
      let json = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: String],
      let expression = json["expression"], !expression.isEmpty,
      let value = MathEngine.evaluate(expression)
    else { return }
    let answer = MathEngine.spoken(value)
    if ai.mathStyle == .explain {
      let steps = try await ai.client.ask(
        system: system(Prompts.mathExplain(answer: answer)),
        user: "Question: \(line)\nExpression: \(expression)"
      )
      say("It's \(answer). \(steps)")
    } else {
      say("It's \(answer).")
    }
  }

  /// Asks Claude something about the recent conversation and says the answer.
  private func ask(_ instruction: String, recent: Int) async throws {
    let reply = try await ai.client.ask(
      system: system(instruction),
      user: "Conversation so far:\n\(conversation?.recent(recent) ?? "")\nThem (still talking): \(partial)"
    )
    say(reply)
  }

  /// Runs one Claude job at a time per feature, so calls never pile up.
  private func run(_ name: String, _ job: @escaping @MainActor () async throws -> Void) {
    guard !busy.contains(name) else { return }
    busy.insert(name)
    Task { @MainActor in
      defer { self.busy.remove(name) }
      do {
        try await job()
      } catch {
        self.status = "\(name.capitalized): \(error.localizedDescription)"
      }
    }
  }

  private func system(_ instruction: String) -> String {
    Prompts.base(aboutMe: ai.aboutMe, goal: ai.goal) + "\n\n" + instruction
  }

  private var languageName: String {
    Locale.current.localizedString(forIdentifier: ai.translateFrom) ?? ai.translateFrom
  }

  static func hasClaim(_ text: String) -> Bool {
    if text.contains(where: \.isNumber) { return true }
    let lower = text.lowercased()
    let cues = ["first", "biggest", "largest", "richest", "oldest", "president", "invented", "record", "percent", "million", "billion", "won the", "died", "born"]
    return cues.contains { lower.contains($0) }
  }

  static func mentionsPlace(_ text: String) -> Bool {
    let lower = text.lowercased()
    let cues = ["going to", "go to", "headed to", "heading to", "meet at", "meet you at", "let's go", "lets go", "pull up", "slide to", "come to", "on my way to", "stop by", "get to"]
    return cues.contains { lower.contains($0) }
  }

  private func save(_ value: Bool, _ key: String) {
    UserDefaults.standard.set(value, forKey: key)
  }

  private func fail(_ message: String) {
    errorMessage = message
    showError = true
  }
}

/// Hands mic audio from the audio thread to the speech request.
final class AudioFeed: @unchecked Sendable {
  private let lock = NSLock()
  private var _request: SFSpeechAudioBufferRecognitionRequest?
  private var _muted = false

  var request: SFSpeechAudioBufferRecognitionRequest? {
    lock.lock()
    defer { lock.unlock() }
    return _request
  }

  var muted: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _muted
    }
    set {
      lock.lock()
      _muted = newValue
      lock.unlock()
    }
  }

  func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock()
    _request = request
    lock.unlock()
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let request = _muted ? nil : _request
    lock.unlock()
    request?.append(buffer)
  }

  /// Loudness of a buffer in dB (0 is the loudest possible).
  static func level(of buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -80 }
    return level(of: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
  }

  static func level(of samples: UnsafeBufferPointer<Float>) -> Float {
    guard !samples.isEmpty else { return -80 }
    var sum: Float = 0
    for sample in samples { sum += sample * sample }
    let rms = (sum / Float(samples.count)).squareRoot()
    return max(20 * log10(max(rms, 1e-7)), -80)
  }
}
