//
// CoachViewModel.swift
//
// Coach mode. The glasses camera watches your screen while you play or
// work; every few seconds Claude looks at the newest picture, keeps running
// notes, and calls out what to do, like a manager on the touchline. At the
// end, a coach's report is saved for tonight's Obsidian notes.
//
// The session and stream steps follow Meta's CameraAccess sample, like
// Reading does.
//

import AVFoundation
import MWDATCamera
import MWDATCore
import Observation
import UIKit

@Observable
@MainActor
final class CoachViewModel {
  // MARK: - What the screen shows

  private(set) var isOn = false
  private(set) var status = "Off"
  private(set) var latestFrame: UIImage?
  private(set) var lastCall: String?
  private(set) var notes = ""
  private(set) var calls: [String] = []
  private(set) var goals: [String] = []
  private(set) var problem: String?
  private(set) var report: String?
  private(set) var isWritingReport = false

  var game: CoachGame { didSet { UserDefaults.standard.set(game.rawValue, forKey: "coach.game") } }
  var pace: CoachPace { didSet { UserDefaults.standard.set(pace.rawValue, forKey: "coach.pace") } }
  var talkMode: FeatureMode { didSet { UserDefaults.standard.set(talkMode.rawValue, forKey: "coach.talk") } }
  var speechRate: Float = 0.52
  /// Scan words, numbers, lines and shapes on the phone before each look.
  var scanScreen: Bool { didSet { UserDefaults.standard.set(scanScreen, forKey: "coach.scan") } }
  private(set) var lastScan: String?
  /// Listen's mic, so Coach hears you mid-game.
  @ObservationIgnored weak var ears: ListenViewModel?
  @ObservationIgnored private var scan = ScreenScan()
  @ObservationIgnored private var heardLines: [String] = []

  // MARK: - Private

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let ai: AISettings
  @ObservationIgnored private let voice: HumanVoice
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var looking = false
  @ObservationIgnored private var speaking = false
  @ObservationIgnored private var startedAt = Date()
  @ObservationIgnored private var sessionID = UUID()

  init(wearables: WearablesInterface, ai: AISettings) {
    self.wearables = wearables
    self.ai = ai
    self.voice = HumanVoice(settings: ai)
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    let d = UserDefaults.standard
    game = CoachGame(rawValue: d.string(forKey: "coach.game") ?? "") ?? .fifa
    pace = CoachPace(rawValue: d.string(forKey: "coach.pace") ?? "") ?? .fast
    talkMode = FeatureMode(rawValue: d.string(forKey: "coach.talk") ?? "") ?? .smart
    scanScreen = d.object(forKey: "coach.scan") == nil ? true : d.bool(forKey: "coach.scan")
  }

  // MARK: - On / off

  func start() async {
    guard !isOn else { return }
    guard ai.hasKey else {
      problem = "Coach needs your Claude key in Settings."
      return
    }
    isOn = true
    problem = nil
    report = nil
    notes = ""
    calls = []
    goals = []
    startedAt = Date()
    sessionID = UUID()
    status = "Connecting to glasses…"
    UIApplication.shared.isIdleTimerDisabled = true
    do {
      if try await wearables.checkPermissionStatus(.camera) != .granted {
        status = "Allow the glasses camera in Meta AI, then come back."
        guard try await wearables.requestPermission(.camera) == .granted else {
          stop()
          problem = "Coach needs the glasses camera."
          return
        }
      }
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      session.statePublisher.listen { [weak self] state in
        Task { @MainActor [weak self] in self?.sessionChanged(state) }
      }.store(in: sessionTokens)
      try session.start()
      // Hear the user the whole time: their words come straight to Coach.
      if let ears {
        ears.coachEars = { [weak self] line in self?.heard(line) }
        if !ears.isOn { await ears.start() }
      }
    } catch {
      stop()
      problem = error.localizedDescription
    }
  }

  func stop() {
    guard isOn || deviceSession != nil else { return }
    let wasOn = isOn
    isOn = false
    loop?.cancel()
    loop = nil
    voice.stop()
    if ears?.coachEars != nil {
      ears?.coachEars = nil
      ears?.stop()
    }
    heardLines = []
    streamTokens.clear()
    camera?.stop()
    camera = nil
    deviceSession?.stop()
    deviceSession = nil
    sessionTokens.clear()
    UIApplication.shared.isIdleTimerDisabled = false
    if wasOn {
      status = calls.isEmpty ? "Off" : "Off. Tap Coach's report for the breakdown."
      saveSession()
    }
  }

  private func sessionChanged(_ state: DeviceSessionState) {
    guard isOn else { return }
    switch state {
    case .started:
      guard camera == nil, let session = deviceSession else { return }
      // Sharper picture, fewer frames: we only need one every few seconds.
      let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 7)
      do {
        guard let newCamera = try session.addCamera(config: config) else {
          problem = "Couldn't open the glasses camera."
          stop()
          return
        }
        camera = newCamera
        newCamera.stream.videoFramePublisher.listen { [weak self] frame in
          guard let image = frame.makeUIImage() else { return }
          Task { @MainActor [weak self] in self?.latestFrame = image }
        }.store(in: streamTokens)
        newCamera.stream.statePublisher.listen { [weak self] state in
          Task { @MainActor [weak self] in
            if state == .streaming { self?.status = "Watching. Look at your screen." }
            if state == .paused { self?.status = "Paused. Tap your glasses to go again." }
          }
        }.store(in: streamTokens)
        newCamera.stream.start()
        startLooking()
      } catch {
        problem = error.localizedDescription
        stop()
      }
    case .stopped:
      if isOn {
        stop()
        problem = "Glasses disconnected."
      }
    default:
      break
    }
  }

  // MARK: - Looking

  private func startLooking() {
    loop?.cancel()
    loop = Task { @MainActor [weak self] in
      while let self, self.isOn, !Task.isCancelled {
        try? await Task.sleep(for: .seconds(self.pace.interval))
        guard self.isOn, !self.looking, let frame = self.latestFrame else { continue }
        await self.look(at: frame)
      }
    }
  }

  private func look(at frame: UIImage) async {
    looking = true
    defer { looking = false }
    guard let jpeg = Self.jpeg(frame) else { return }
    await rescan(frame)
    let heard = heardLines.suffix(3).joined(separator: " | ")
    let spotted = heardLines.suffix(3).flatMap { scan.find($0) }.prefix(5).map { "\($0.zone): \($0.text)" }
    heardLines.removeAll()
    do {
      let reply = try await ai.client.ask(
        system: CoachPrompts.system(game: game, mode: talkMode, aboutMe: ai.aboutMe),
        user: CoachPrompts.look(notes: notes, recentCalls: Array(calls.suffix(3)))
          + CoachPrompts.extra(scan: scan.summary, heard: heard, spotted: spotted.joined(separator: "; ")),
        maxTokens: 2_000,
        effort: "low",
        schema: CoachReply.schema,
        images: [jpeg]
      )
      let parsed = try JSONDecoder().decode(CoachReply.self, from: Data(reply.utf8))
      apply(parsed)
    } catch {
      problem = error.localizedDescription
    }
  }

  /// Uses one look's answer: update notes, log goals, speak the call.
  func apply(_ reply: CoachReply) {
    if !reply.notes.isEmpty { notes = reply.notes }
    var line = reply.say.trimmingCharacters(in: .whitespacesAndNewlines)
    switch reply.event {
    case "goal_for":
      let rated = reply.rating.isEmpty ? "Goal!" : "Goal! \(reply.rating)"
      goals.append(rated)
      line = line.isEmpty ? rated : "\(rated) \(line)"
    case "goal_against":
      goals.append("Conceded: \(line)")
    default:
      break
    }
    guard !line.isEmpty, line != Prompts.quiet else { return }
    calls.append(line)
    lastCall = line
    say(line)
  }

  /// The on-device scan of the newest frame.
  private func rescan(_ frame: UIImage) async {
    guard scanScreen, let image = frame.cgImage else { return }
    scan = await Task.detached(priority: .userInitiated) { ScreenScanner.scan(image) }.value
    lastScan = scan.summary.isEmpty ? nil : scan.summary
  }

  /// Something heard while coaching. Your words get an answer now, using
  /// what's on screen; anything else is kept for the next look.
  func heard(_ line: String) {
    heardLines.append(line)
    if heardLines.count > 6 { heardLines.removeFirst() }
    guard isOn, let frame = latestFrame, let jpeg = Self.jpeg(frame) else { return }
    Task { @MainActor in
      await self.rescan(frame)
      do {
        let answer = try await self.ai.client.ask(
          system: CoachPrompts.system(game: self.game, mode: .always, aboutMe: self.ai.aboutMe),
          user: CoachPrompts.answer(line, notes: self.notes, scan: self.scan.summary),
          maxTokens: 1_000,
          effort: "low",
          images: [jpeg]
        )
        guard answer != Prompts.quiet else { return }
        self.calls.append(answer)
        self.lastCall = answer
        self.say(answer, mustSay: true)
      } catch {
        self.problem = error.localizedDescription
      }
    }
  }

  private func say(_ line: String, mustSay: Bool = false) {
    // Through Listen's mic engine: echo cancelled, so you can talk over it.
    // Calls wait while anyone is talking; answers to you always play.
    if let ears, ears.isOn {
      if mustSay || !ears.isBusyTalking { ears.say(line) }
      return
    }
    // Newest call wins: skip if still talking, so calls never lag behind the game.
    guard !speaking else { return }
    speaking = true
    Task { @MainActor in
      defer { self.speaking = false }
      let ready = await self.voice.prepare(line)
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      try? session.setActive(true)
      await self.voice.play(ready, rate: self.speechRate)
      if let voiceProblem = self.voice.lastError { self.problem = voiceProblem }
    }
  }

  // MARK: - Report and saving

  func writeReport() async {
    guard !isWritingReport, !calls.isEmpty || !notes.isEmpty else { return }
    isWritingReport = true
    defer { isWritingReport = false }
    do {
      report = try await ai.notesClient.ask(
        system: CoachPrompts.report(game: game),
        user: "Notes:\n\(notes)\n\nCalls made:\n\(calls.joined(separator: "\n"))\n\nGoals and moments:\n\(goals.joined(separator: "\n"))",
        maxTokens: 4_000,
        effort: "medium"
      )
      saveSession()
    } catch {
      problem = error.localizedDescription
    }
  }

  /// Saves the session like a talk, so it becomes Obsidian notes tonight.
  private func saveSession() {
    guard !calls.isEmpty || !notes.isEmpty else { return }
    var session = Conversation(id: sessionID, started: startedAt)
    session.ended = Date()
    session.lines = calls.map { ConversationLine(time: Date(), speaker: .them, text: "Coach: \($0)") }
    session.notes = ["\(game.rawValue) coach session", "Coach notes: \(notes)"] + goals
    session.feedback = report
    try? ConversationStore().save(session)
  }


  /// Shrinks a frame to 1024 px on the long side, as JPEG, to keep it fast.
  static func jpeg(_ image: UIImage, maxSide: CGFloat = 1_024) -> Data? {
    let size = image.size
    let scale = min(1, maxSide / max(size.width, size.height, 1))
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return resized.jpegData(compressionQuality: 0.6)
  }
}
