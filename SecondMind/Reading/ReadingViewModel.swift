//
// ReadingViewModel.swift
//
// Reading mode. Opens a session with the glasses, streams the camera at a
// low frame rate, waits until the view holds still, takes a sharp photo,
// finds the words on the phone, and reads them out loud.
//
// The session and stream steps follow CameraViewModel in Meta's
// CameraAccess sample.
//

import MWDATCamera
import MWDATCore
import Observation
import SwiftUI
import UIKit

@Observable
@MainActor
final class ReadingViewModel {
  // MARK: - What the screen shows

  private(set) var hasActiveDevice = false
  private(set) var sessionState: DeviceSessionState = .idle
  private(set) var streamState: StreamState = .stopped
  private(set) var latestFrame: UIImage?
  private(set) var hasReceivedFirstFrame = false
  private(set) var isWorking = false
  private(set) var status = "Off"
  private(set) var lastReadText: String?
  /// Bumps every time something is sent to the speaker. Tests watch this.
  private(set) var spokenCount = 0

  /// True while the user wants Reading on (even if the glasses are still connecting).
  private(set) var isOn = false

  var showError = false
  var errorMessage = ""
  var showCameraPermissionPrompt = false

  /// Read on its own when text holds still. Off means only the Read button reads.
  var autoRead: Bool = true {
    didSet { UserDefaults.standard.set(autoRead, forKey: Keys.autoRead) }
  }
  /// Speech speed. Apple's normal speed is 0.5.
  var speechRate: Float = 0.45 {
    didSet { UserDefaults.standard.set(speechRate, forKey: Keys.rate) }
  }
  /// Real glasses: take a full photo for sharper text. Practice mode turns
  /// this off and reads the live frame instead.
  var usePhotoCapture = true

  var isStreaming: Bool { streamState == .streaming }
  var isPaused: Bool { streamState == .paused }

  // MARK: - Private

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private let speaker: Speaker
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private var detector = StillnessDetector()
  @ObservationIgnored private var pendingPhotoID = 0
  @ObservationIgnored private var pendingForce = false
  @ObservationIgnored private var awaitingPhotoID: Int?
  @ObservationIgnored private var restartWhenStopped = false
  @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private let photoTimeout: Duration

  private enum Keys {
    static let autoRead = "reading.autoRead"
    static let rate = "reading.rate"
  }

  init(wearables: WearablesInterface, speaker: Speaker, photoTimeout: Duration = .seconds(10)) {
    self.wearables = wearables
    self.speaker = speaker
    self.photoTimeout = photoTimeout
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    if UserDefaults.standard.object(forKey: Keys.autoRead) != nil {
      autoRead = UserDefaults.standard.bool(forKey: Keys.autoRead)
    }
    if UserDefaults.standard.object(forKey: Keys.rate) != nil {
      speechRate = UserDefaults.standard.float(forKey: Keys.rate)
    }
    watchDevices()
    watchAppLifecycle()
  }

  // MARK: - On / off

  func start() {
    guard !isOn else { return }
    isOn = true
    detector.reset()
    UIApplication.shared.isIdleTimerDisabled = true
    status = "Connecting to glasses…"
    if deviceSession == nil {
      openSession()
    } else if sessionState == .started {
      Task { await startStreamIfAllowed() }
    } else if sessionState == .stopping {
      restartWhenStopped = true
    }
  }

  func stop() {
    isOn = false
    speaker.stop()
    UIApplication.shared.isIdleTimerDisabled = false
    status = "Off"
    deviceSession?.stop()
  }

  // MARK: - Reading

  /// Reads what the glasses see right now, even if it was read before.
  func readNow() {
    guard isOn else { return }
    beginRead(force: true)
  }

  func sayAgain() {
    guard let text = lastReadText else { return }
    say(text)
  }

  func stopTalking() {
    speaker.stop()
  }

  // MARK: - Camera permission

  func confirmCameraPermission() async {
    showCameraPermissionPrompt = false
    guard let session = deviceSession, session.state == .started, camera == nil else { return }
    do {
      guard try await wearables.requestPermission(.camera) == .granted else {
        fail("Camera permission was not given. Reading needs the glasses camera.")
        return
      }
    } catch {
      fail(error.localizedDescription)
      return
    }
    beginStream(on: session)
  }

  func dismissError() {
    showError = false
  }

  // MARK: - Session

  private func openSession() {
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      observe(session)
      sessionState = .starting
      try session.start()
    } catch {
      fail(error.localizedDescription)
      sessionState = .idle
      cleanupSession()
    }
  }

  private func observe(_ session: DeviceSession) {
    session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in self?.sessionChanged(state) }
    }.store(in: sessionTokens)
    session.errorPublisher.listen { [weak self] error in
      let message = error.localizedDescription
      Task { @MainActor [weak self] in self?.liveError(message) }
    }.store(in: sessionTokens)
  }

  private func sessionChanged(_ state: DeviceSessionState) {
    sessionState = state
    switch state {
    case .started:
      if isOn, camera == nil {
        Task { await startStreamIfAllowed() }
      }
    case .stopped:
      cleanupSession()
      if restartWhenStopped {
        restartWhenStopped = false
        if isOn { openSession() }
      } else if isOn {
        // The glasses dropped off. Turn off cleanly so the button can retry.
        isOn = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = "Glasses disconnected. Tap Start to try again."
      }
    default:
      break
    }
  }

  private func cleanupSession() {
    sessionTokens.clear()
    deviceSession = nil
  }

  // MARK: - Stream

  private func startStreamIfAllowed() async {
    guard let session = deviceSession, session.state == .started, camera == nil else { return }
    do {
      if try await wearables.checkPermissionStatus(.camera) == .granted {
        beginStream(on: session)
      } else {
        status = "Needs camera permission"
        showCameraPermissionPrompt = true
      }
    } catch {
      fail(error.localizedDescription)
    }
  }

  private func beginStream(on session: DeviceSession) {
    guard camera == nil else { return }
    // Raw frames decode straight to images. 7 fps is enough to tell when
    // the view is still and saves glasses battery.
    let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 7)
    do {
      guard let newCamera = try session.addCamera(config: config) else {
        fail("Couldn't open the glasses camera. Try again.")
        return
      }
      camera = newCamera
      listen(to: newCamera.stream)
      streamState = .starting
      newCamera.stream.start()
    } catch {
      camera = nil
      fail(error.localizedDescription)
    }
  }

  private func listen(to stream: MWDATCamera.Stream) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in self?.streamChanged(state) }
    }.store(in: streamTokens)

    stream.videoFramePublisher.listen { [weak self] frame in
      guard let image = frame.makeUIImage() else { return }
      Task { @MainActor [weak self] in self?.frameArrived(image) }
    }.store(in: streamTokens)

    stream.photoDataPublisher.listen { [weak self] photo in
      let image = UIImage(data: photo.data)
      Task { @MainActor [weak self] in self?.photoArrived(image) }
    }.store(in: streamTokens)

    stream.errorPublisher.listen { [weak self] error in
      let message = error.localizedDescription
      Task { @MainActor [weak self] in self?.liveError(message) }
    }.store(in: streamTokens)
  }

  private func streamChanged(_ state: StreamState) {
    streamState = state
    switch state {
    case .streaming:
      status = autoRead ? "Looking for words" : "Ready. Tap Read."
    case .paused:
      status = "Paused. Tap your glasses to go again."
    case .waitingForDevice:
      status = "Waiting for glasses. Put them on."
    case .stopped:
      streamTokens.clear()
      camera?.stop()
      camera = nil
      latestFrame = nil
      hasReceivedFirstFrame = false
      isWorking = false
    default:
      break
    }
  }

  private func frameArrived(_ image: UIImage) {
    latestFrame = image
    hasReceivedFirstFrame = true
    let thumb = StillnessDetector.thumbnail(of: image)
    let timeToRead = detector.feed(thumb)
    if timeToRead, autoRead, !isWorking, !speaker.isSpeaking {
      beginRead(force: false)
    }
  }

  // MARK: - Read pipeline

  private func beginRead(force: Bool) {
    guard !isWorking else { return }
    isWorking = true
    status = "Reading…"
    Task { await runRead(force: force) }
  }

  private func runRead(force: Bool) async {
    if usePhotoCapture, isStreaming, let stream = camera?.stream {
      pendingPhotoID += 1
      let id = pendingPhotoID
      awaitingPhotoID = id
      pendingForce = force
      trace("taking photo")
      // Off the main thread so the screen never freezes while the glasses work.
      let started = await Task.detached { stream.capturePhoto(format: .jpeg) }.value
      trace("photo started: \(started)")
      if started {
        try? await Task.sleep(for: photoTimeout)
        // The photo already came back and was handled.
        guard awaitingPhotoID == id else { return }
        trace("no photo came back, using the live frame")
      }
      awaitingPhotoID = nil
    }
    await recognize(latestFrame, force: force)
  }

  private func photoArrived(_ image: UIImage?) {
    trace("photo arrived: \(image != nil)")
    guard awaitingPhotoID != nil else { return }
    awaitingPhotoID = nil
    let force = pendingForce
    Task { await recognize(image ?? latestFrame, force: force) }
  }

  private func recognize(_ image: UIImage?, force: Bool) async {
    defer { isWorking = false }
    guard let image else {
      status = "No picture yet"
      return
    }
    let text: String
    do {
      trace("finding words")
      text = try await TextRecognizer.recognize(image)
      trace("found \(text.count) characters")
    } catch {
      status = "Couldn't read that"
      return
    }
    guard isOn else { return }

    guard TextTools.hasRealWords(text) else {
      status = autoRead ? "Looking for words" : "No words found"
      if force { say("I don't see any words.") }
      return
    }
    if !force, !TextTools.isNew(text, comparedTo: lastReadText) {
      status = "Same words as before"
      return
    }
    lastReadText = text
    say(text)
    status = "Read it. Move to new words, or tap Read."
  }

  private func say(_ text: String) {
    speaker.speak(text, rate: speechRate)
    spokenCount += 1
  }

  // MARK: - Device and app watching

  private func watchDevices() {
    deviceMonitorTask = Task { [weak self] in
      guard let selector = self?.deviceSelector else { return }
      for await deviceId in selector.activeDeviceStream() {
        self?.hasActiveDevice = deviceId != nil
      }
    }
  }

  private func watchAppLifecycle() {
    // iPhone pauses apps in the background, so close the session cleanly.
    lifecycleTask = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
        guard let self else { return }
        if self.isOn { self.stop() }
      }
    }
  }

  private func trace(_ text: String) {
    #if DEBUG
    NSLog("[SecondMindTest] reading: \(text)")
    #endif
  }

  /// Errors while turning off on purpose are just teardown noise.
  private func liveError(_ message: String) {
    guard isOn else { return }
    fail(message)
  }

  private func fail(_ message: String) {
    errorMessage = message
    showError = true
  }
}
