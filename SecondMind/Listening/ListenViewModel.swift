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
  /// Your-turn beep.
  var turnBeeps: Bool { didSet { save(turnBeeps, "listen.turnBeeps") } }
  var holdOnBeep: Bool { didSet { save(holdOnBeep, "listen.holdOn") } }
  var awkwardBeep: Bool { didSet { save(awkwardBeep, "listen.awkward") } }
  /// Live guess of how their sentence ends.
  private(set) var prediction: String?
  /// Answer to a typed math problem.
  private(set) var mathAnswer: String?
  /// Reads remembered notes (Obsidian People pages) for names in the text.
  @ObservationIgnored var memory: ((String) -> String)?
  /// Writes the "My Voice" note into the Obsidian vault.
  @ObservationIgnored var saveVoiceNote: ((VoiceProfile) -> Void)?
  /// Your voice: pitch, loudness, pace, and words. Made once, kept forever.
  private(set) var voiceProfile: VoiceProfile?
  /// Opens the voice setup screen.
  var showVoiceSetup = false
  /// Turns up quiet and mumbled voices before speech recognition hears them.
  var boostQuiet: Bool {
    didSet {
      save(boostQuiet, "listen.boost")
      feed.boost = boostQuiet
    }
  }
  @ObservationIgnored private var linesLearned = 0

  /// Only treat real speech as conversation, not music, singing, or noise.
  var ignoreNoise: Bool { didSet { save(ignoreNoise, "listen.ignoreNoise") } }
  /// What the sound classifier hears when it isn't speech, for the screen.
  private(set) var soundNote: String?
  /// Read the room: Claude's running read of the conversation.
  private(set) var situation: SituationRead?
  @ObservationIgnored private var gate: SoundGate?
  @ObservationIgnored private var speechFrames = 0
  @ObservationIgnored private var musicFrames = 0
  @ObservationIgnored private var linesAtLastRead = 0
  @ObservationIgnored private var lastReadAt: TimeInterval = -.infinity
  @ObservationIgnored private var lastOutcomeAt: TimeInterval = -.infinity
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
  /// A line just ended and a Best Reply hint is owed for it.
  @ObservationIgnored private var hintWanted = false
  /// When the transcript last got new words (speech, no matter how loud).
  @ObservationIgnored private var lastWordsAt: TimeInterval = 0
  @ObservationIgnored private var lastTheirLineAt: TimeInterval = -.infinity
  @ObservationIgnored private var helpedForLineAt: TimeInterval = -.infinity
  @ObservationIgnored private var predictedTheirWords = 0

  /// The last thing that went wrong, shown on the Listen screen.
  private(set) var problem: String?

  init(ai: AISettings) {
    self.ai = ai
    self.voice = HumanVoice(settings: ai)
    let d = UserDefaults.standard
    func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
    boostQuiet = flag("listen.boost", true)
    ignoreNoise = flag("listen.ignoreNoise", true)
    turnBeeps = flag("listen.turnBeeps", true)
    holdOnBeep = flag("listen.holdOn", true)
    awkwardBeep = flag("listen.awkward", true)
    moodChimes = flag("listen.mood", true)
    longTalkNudge = flag("listen.longTalk", false)
    helpWhenStuck = flag("listen.claude", true)
    clearVoice = flag("listen.clearVoice", true)
    if d.object(forKey: "listen.myLevel") != nil {
      detector.myLevel = d.float(forKey: "listen.myLevel")
    }
    navigator.say = { [weak self] text in self?.say(text) }
    feed.boost = boostQuiet
    if let saved = VoiceProfile.load() { useProfile(saved) }
  }

  var isCalibrated: Bool {
    voiceProfile != nil || UserDefaults.standard.object(forKey: "listen.myLevel") != nil
  }

  /// Uses a voice profile from now on (from setup, or restored from Obsidian).
  func useProfile(_ profile: VoiceProfile) {
    voiceProfile = profile
    detector.profile = profile
    detector.myLevel = profile.normalLevel
  }

  /// Saves the profile everywhere, including Obsidian.
  private func storeProfile() {
    guard let voiceProfile else { return }
    voiceProfile.save()
    saveVoiceNote?(voiceProfile)
  }

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
    fresh.profile = voiceProfile
    detector = fresh
    mood = MoodDetector()
    pendingHint = nil
    situation = nil
    linesAtLastRead = 0
    lastReadAt = -.infinity
    lastOutcomeAt = -.infinity
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
    storeProfile()
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
      // Get the voice ready first (download it) while the mic keeps listening.
      let ready = await voice.prepare(line)
      feed.muted = true
      let paused = isOn && clearVoice
      if paused { pauseMicForVoice() }
      if !isOn {
        // Testing the voice from Settings: plain playback, even on silent mode.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
      }
      if paused || !isOn {
        // Give Bluetooth a moment to switch the glasses to full-quality audio,
        // so the first words aren't lost.
        try? await Task.sleep(for: .milliseconds(450))
      }
      await voice.play(ready, rate: speechRate)
      if let voiceProblem = voice.lastError { report(voiceProblem) }
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
    let rate = format.sampleRate
    let gate = SoundGate(format: format)
    self.gate = gate
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
      gate?.analyze(buffer)
      let level = AudioFeed.level(of: buffer)
      var pitch: Float?
      if level > -60, let data = buffer.floatChannelData, buffer.frameLength > 0 {
        pitch = PitchDetector.pitch(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)), sampleRate: rate)
      }
      feed.append(buffer)
      Task { @MainActor [weak self] in self?.heard(level: level, pitch: pitch) }
    }
    engine.prepare()
    try engine.start()
  }

  private func teardownAudio() {
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
    feed.set(nil)
    gate = nil
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
    if let text, text != partial {
      partial = text
      // New words mean someone is talking, however quiet the mic level is.
      let now = Date().timeIntervalSince(startedAt)
      lastWordsAt = now
      if utteranceStartedAt == nil { utteranceStartedAt = now }
      // Lyrics and TV aren't the conversation: don't build replies to them.
      let musicOn = ignoreNoise && (gate?.scores.isMusic ?? false)
      if !musicOn {
        predictReply()
        predictTheirWords()
      }
    }
    guard done else { return }
    predictedWords = 0
    predictedTheirWords = 0
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
    let mostlyMusic = ignoreNoise && musicFrames > speechFrames
    speechFrames = 0
    musicFrames = 0
    guard !clean.isEmpty, conversation != nil else { return }
    // Song lyrics or a TV show, not someone talking to you: leave it out.
    if mostlyMusic {
      meFrames = 0
      themFrames = 0
      pendingHint = nil
      hintWanted = false
      return
    }
    // Only call it yours when your louder voice clearly dominated; otherwise
    // assume it was them, so they always get an answer.
    let who: Talker = meFrames > max(themFrames, 2) ? .me : .them
    meFrames = 0
    themFrames = 0
    conversation?.lines.append(ConversationLine(time: Date(), speaker: who, text: clean))
    autosave()
    readTheRoom()
    if who == .them {
      lastTheirLineAt = Date().timeIntervalSince(startedAt)
      deliverBestReply()
    } else if voiceProfile != nil {
      // Keep learning how you talk.
      voiceProfile?.learn(clean)
      linesLearned += 1
      if linesLearned % 10 == 0 { voiceProfile?.save() }
    }
    react(to: clean, from: who)
  }

  /// Best Reply: after every line from them, say the hint. Uses the one
  /// built while they were talking if it's ready; otherwise asks now and
  /// says it the moment it arrives.
  private func deliverBestReply() {
    guard ai.debate else { return }
    guard ai.hasKey else {
      report("Best Reply needs your Claude key in Settings.")
      return
    }
    let now = Date().timeIntervalSince(startedAt)
    if let hint = pendingHint, now - hint.at < 20 {
      pendingHint = nil
      say(hint.text)
      return
    }
    hintWanted = true
    requestHint(heard: "")
  }

  /// Keeps a copy on disk, so nothing is lost if the app is closed mid-talk.
  private func autosave() {
    guard let convo = conversation, convo.lines.count % 5 == 0 else { return }
    try? store.save(convo)
  }

  // MARK: - Every level reading

  private func heard(level: Float, pitch: Float? = nil) {
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

    // Music, singing, wind, traffic: heard, but not treated as people talking.
    let sound = gate?.scores ?? SoundScores(speech: 1)
    let isSpeech = !ignoreNoise || sound.isSpeech
    if level > detector.noiseFloor + 6 {
      if isSpeech { speechFrames += 1 } else if sound.isMusic { musicFrames += 1 }
    }
    if ignoreNoise, !sound.isSpeech, level > detector.noiseFloor + 6 {
      soundNote = sound.isMusic ? "Music playing, ignoring it" : "Background noise, ignoring it"
    } else if sound.isSpeech {
      soundNote = nil
    }

    let events = detector.feed(level: isSpeech ? level : -80, pitch: isSpeech ? pitch : nil, at: now)
    talker = detector.current

    switch detector.current {
    case .me:
      meFrames += 1
      lastSpeechAt = now
    case .them:
      themFrames += 1
      lastSpeechAt = now
    case .nobody:
      break
    }

    // A line ends when no new words have come for a second (or it gets very
    // long). Words, not loudness, so quiet mics still work.
    let lastActivity = max(lastWordsAt, lastSpeechAt)
    if let started = utteranceStartedAt, feed.request != nil, !partial.isEmpty,
      now - lastActivity >= 1.0 || now - started >= 50
    {
      finishUtterance()
      utteranceStartedAt = nil
    }

    // Help when I freeze, even if the loudness guess missed the turn.
    if helpWhenStuck, ai.bestReplyMode != .always, ai.hasKey, lastTheirLineAt > helpedForLineAt,
      now - lastTheirLineAt >= 3.5, now - lastActivity >= 3.5, now - lastHelpAt >= 15
    {
      helpedForLineAt = lastTheirLineAt
      lastHelpAt = now
      if awkwardBeep { play(.awkwardPause) }
      run("stuck") {
        try await self.ask(Prompts.stuck + "\n\n" + Prompts.styleGuide(self.ai.replyStyle), recent: 14)
      }
    }

    for event in events { handle(event, at: now) }
  }

  private func handle(_ event: TurnEvent, at now: TimeInterval) {
    guard !isCalibrating else { return }
    switch event {
    case .yourTurn:
      lastYourTurnAt = now
      if turnBeeps { play(.yourTurn) }
    case .holdOn:
      if holdOnBeep { play(.holdOn) }
    case .talkingLong:
      if longTalkNudge { play(.talkingLong) }
    case .theyFinished(let average, let duration):
      if moodChimes,
        let change = mood.theyFinished(averageLevel: average, duration: duration, text: lastThemText, at: now)
      {
        play(.mood(change))
      }
    case .stalled:
      if awkwardBeep { play(.awkwardPause) }
      if helpWhenStuck, ai.bestReplyMode != .always, ai.hasKey, now - lastHelpAt >= 15 {
        lastHelpAt = now
        helpedForLineAt = lastTheirLineAt
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
      let lineID = conversation?.lines.last?.id
      run("translate") {
        let english = try await self.ai.client.ask(
          system: self.system(Prompts.translate(from: self.languageName)),
          user: "Newest line: \(line)",
          maxTokens: 1_000
        )
        guard english != Prompts.quiet else { return }
        // Keep the English in the transcript so every other feature runs on it.
        if let id = lineID, let index = self.conversation?.lines.firstIndex(where: { $0.id == id }) {
          self.conversation?.lines[index].text = "\(english) [said: \(line)]"
        }
        self.say(english)
      }
    }

    let factGap: TimeInterval = ai.factCheckMode == .always ? 10 : 20
    if ai.factCheck, Self.hasClaim(line), now - lastFactCheckAt >= factGap {
      lastFactCheckAt = now
      run("fact") {
        let fix = try await self.ai.client.ask(
          system: self.system(Prompts.factCheck(self.ai.factCheckMode)),
          user: "Conversation so far:\n\(self.conversation?.recent(8) ?? line)",
          maxTokens: 4_000,
          webSearch: true
        )
        guard fix != Prompts.quiet else { return }
        self.conversation?.notes.append("Fact check: \(fix)")
        self.say(fix)
      }
    }

    let always = ai.consistencyMode == .always
    if ai.consistency, lines >= (always ? 3 : 6), lines - linesAtLastConsistency >= (always ? 2 : 4),
      now - lastConsistencyAt >= (always ? 20 : 45)
    {
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
    // Skip only when it's clearly your own voice.
    guard ai.debate, ai.hasKey, meFrames <= max(themFrames, 2) else { return }
    let now = Date().timeIntervalSince(startedAt)
    let words = partial.split(separator: " ").count
    // Start early and refresh often, so the hint is ready the instant they stop.
    let enoughNew = words - predictedWords >= 4
    let stale = words > predictedWords && now - lastPredictAt >= 2
    guard words >= 3, enoughNew || stale else { return }
    predictedWords = words
    lastPredictAt = now
    requestHint(heard: partial)
  }

  /// Asks Claude for the Best Reply. If a finished line is waiting on it,
  /// says it right away; otherwise keeps it ready for when they stop.
  private func requestHint(heard: String) {
    run("debate") {
      let still = heard.isEmpty ? "" : "\nThem (still talking): \(heard)"
      let hint = try await self.ai.client.ask(
        system: self.system(
          Prompts.bestReply(self.ai.replyStyle, mode: self.ai.bestReplyMode)
            + (self.ai.influence ? "\n\n" + Prompts.influence : "")
        ),
        user: "Conversation so far:\n\(self.conversation?.recent(12) ?? "")\(still)"
      )
      if self.hintWanted {
        self.hintWanted = false
        self.pendingHint = nil
        self.say(hint)
      } else {
        self.pendingHint = (hint, Date().timeIntervalSince(self.startedAt))
      }
    }
  }

  /// Predict their words: guesses how their sentence ends while they talk.
  private func predictTheirWords() {
    guard ai.predictWords, ai.hasKey, meFrames <= max(themFrames, 2) else { return }
    let words = partial.split(separator: " ").count
    guard words >= 3, words - predictedTheirWords >= 3 else { return }
    predictedTheirWords = words
    let heard = partial
    run("predict") {
      let guess = try await self.ai.client.ask(
        system: self.system(Prompts.predictWords),
        user: "Conversation so far:\n\(self.conversation?.recent(8) ?? "")\nThem (mid-sentence): \(heard)",
        maxTokens: 1_000
      )
      self.prediction = guess
      if self.ai.predictSpoken { self.say(guess) }
    }
  }

  // MARK: - Read the room and likely outcomes

  /// Refreshes the running read every few lines, in the background, so
  /// hints come out fast and already understand what you're going for.
  private func readTheRoom() {
    guard ai.readRoom || ai.outcomes || ai.influence, ai.hasKey else { return }
    let lines = conversation?.lines.count ?? 0
    let now = Date().timeIntervalSince(startedAt)
    guard lines >= 2, lines - linesAtLastRead >= 3 || now - lastReadAt >= 30 else { return }
    linesAtLastRead = lines
    lastReadAt = now
    run("read") {
      let reply = try await self.ai.client.ask(
        system: Prompts.base(aboutMe: self.ai.aboutMe, goal: self.ai.goal) + "\n\n"
          + Prompts.situation(influence: self.ai.influence, outcomes: self.ai.outcomes)
          + (self.voiceProfile.map { "\n\n" + $0.styleNote } ?? "")
          + self.memoryNote,
        user: "Conversation so far:\n\(self.conversation?.recent(30) ?? "")",
        maxTokens: 2_000,
        schema: SituationRead.schema
      )
      let read = try JSONDecoder().decode(SituationRead.self, from: Data(reply.utf8))
      self.situation = read
      self.speakOutcome(read)
    }
  }

  /// Likely outcomes: only at real turning points, at most once a minute.
  private func speakOutcome(_ read: SituationRead) {
    guard ai.outcomes, read.turningPoint, let first = read.outcomes.first else { return }
    let now = Date().timeIntervalSince(startedAt)
    guard now - lastOutcomeAt >= 60 else { return }
    lastOutcomeAt = now
    conversation?.notes.append("Likely outcome: \(read.outcomes.joined(separator: "; "))")
    say("Likely: \(first)")
  }

  // MARK: - Typed math and presets

  /// Math typed on the phone instead of heard.
  func solveTyped(_ problem: String) {
    let text = problem.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    // Plain arithmetic needs no Claude at all.
    if let value = MathEngine.evaluate(text) {
      mathAnswer = MathEngine.spoken(value)
      if isOn { say("It's \(mathAnswer!).") }
      return
    }
    guard ai.hasKey else {
      report("Word problems need your Claude key in Settings.")
      return
    }
    run("math") { try await self.solve(text, typed: true) }
  }

  /// One tap to set the switches for a situation.
  func apply(_ preset: Preset) {
    switch preset {
    case .social:
      ai.influence = false; ai.outcomes = false; ai.readRoom = true
      ai.bestReplyMode = .smart
      ai.replyStyle = .adaptive
      helpWhenStuck = true
      turnBeeps = true; holdOnBeep = true; awkwardBeep = true
      moodChimes = true; longTalkNudge = false
      ai.factCheckMode = .off; ai.consistencyMode = .off; ai.predictWords = false
    case .interview:
      ai.influence = true; ai.outcomes = true; ai.readRoom = true
      ai.bestReplyMode = .always
      ai.replyStyle = .presentation
      helpWhenStuck = true
      turnBeeps = true; holdOnBeep = true; awkwardBeep = true
      moodChimes = false; longTalkNudge = true
      ai.factCheckMode = .off; ai.consistencyMode = .off; ai.predictWords = true
    case .date:
      ai.influence = false; ai.outcomes = false; ai.readRoom = true
      ai.bestReplyMode = .smart
      ai.replyStyle = .flirty
      helpWhenStuck = true
      turnBeeps = true; holdOnBeep = true; awkwardBeep = true
      moodChimes = true; longTalkNudge = true
      ai.factCheckMode = .off; ai.consistencyMode = .off; ai.predictWords = false
    case .argument:
      ai.influence = true; ai.outcomes = true; ai.readRoom = true
      ai.bestReplyMode = .always
      ai.replyStyle = .adaptive
      helpWhenStuck = true
      turnBeeps = true; holdOnBeep = true; awkwardBeep = false
      moodChimes = true; longTalkNudge = false
      ai.factCheckMode = .smart; ai.consistencyMode = .smart; ai.predictWords = true
    case .beepsOnly:
      ai.influence = false; ai.outcomes = false
      ai.bestReplyMode = .off
      helpWhenStuck = false
      turnBeeps = true; holdOnBeep = true; awkwardBeep = true
      moodChimes = true; longTalkNudge = false
      ai.factCheckMode = .off; ai.consistencyMode = .off; ai.predictWords = false
    case .allOff:
      ai.influence = false; ai.outcomes = false; ai.readRoom = false
      ai.bestReplyMode = .off
      helpWhenStuck = false
      turnBeeps = false; holdOnBeep = false; awkwardBeep = false
      moodChimes = false; longTalkNudge = false
      ai.factCheckMode = .off; ai.consistencyMode = .off; ai.predictWords = false
      ai.translate = false; ai.math = false; ai.planDetection = false
    }
    status = "\(preset.rawValue) setup on."
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

  private func solve(_ line: String, typed: Bool = false) async throws {
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
    else {
      if typed { mathAnswer = "Couldn't turn that into math. Try rewording it." }
      return
    }
    let answer = MathEngine.spoken(value)
    var spoken = "It's \(answer)."
    if ai.mathStyle == .explain {
      let steps = try await ai.client.ask(
        system: system(Prompts.mathExplain(answer: answer)),
        user: "Question: \(line)\nExpression: \(expression)"
      )
      spoken += " \(steps)"
    }
    if typed { mathAnswer = spoken }
    if !typed || isOn { say(spoken) }
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
        if name == "debate" { self.hintWanted = false }
        self.report("\(name == "debate" ? "Best Reply" : name.capitalized): \(error.localizedDescription)")
      }
    }
  }

  private func system(_ instruction: String) -> String {
    var text = Prompts.base(aboutMe: ai.aboutMe, goal: ai.goal) + "\n\n" + instruction
    if let voiceProfile { text += "\n\n" + voiceProfile.styleNote }
    if ai.readRoom || ai.influence, let situation { text += "\n\n" + situation.brief }
    text += memoryNote
    return text
  }

  /// Past talks: People notes for anyone named in this conversation.
  private var memoryNote: String {
    guard ai.useMemory, let memory, let transcript = conversation?.transcript else { return "" }
    let notes = memory(transcript)
    return notes.isEmpty ? "" : Prompts.memory(notes)
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

  /// Shows a problem on the Listen screen instead of failing silently.
  private func report(_ message: String) {
    problem = message
  }

  func clearProblem() {
    problem = nil
  }

  /// One tap check of the whole chain: Claude key, Claude, and the voice.
  func testClaudeAndVoice() {
    guard ai.hasKey else {
      report("No Claude key saved yet. Paste it in Settings and tap Save.")
      say("I don't have your Claude key yet.")
      return
    }
    problem = nil
    lastSaid = "Asking Claude…"
    run("test") {
      let hello = try await self.ai.client.ask(
        system: self.system("Greet the user in one short, warm sentence so they know you're working."),
        user: "Say hi."
      )
      self.say(hello)
    }
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

  private var _boost = true

  /// Turn up quiet speech before speech recognition hears it.
  var boost: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _boost
    }
    set {
      lock.lock()
      _boost = newValue
      lock.unlock()
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let request = _muted ? nil : _request
    let boost = _boost
    lock.unlock()
    guard let request else { return }
    request.append(boost ? Self.boosted(buffer) : buffer)
  }

  /// How much to turn up a buffer: quiet speech gets lifted toward a normal
  /// level (up to 6 times louder); silence and loud speech are left alone.
  static func gain(forLevel level: Float) -> Float {
    guard level > -62, level < -26 else { return 1 }
    let wanted: Float = -24
    return min(pow(10, (wanted - level) / 20), 6)
  }

  static func boosted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    let gain = gain(forLevel: level(of: buffer))
    guard gain > 1.05,
      let source = buffer.floatChannelData,
      let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
      let target = copy.floatChannelData
    else { return buffer }
    copy.frameLength = buffer.frameLength
    let frames = Int(buffer.frameLength)
    for channel in 0..<Int(buffer.format.channelCount) {
      for i in 0..<frames {
        target[channel][i] = max(-1, min(1, source[channel][i] * gain))
      }
    }
    return copy
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
