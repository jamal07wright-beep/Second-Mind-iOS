//
// MockGlassesReadingTests.swift
//
// Runs Reading end to end against Meta's mock glasses: connect, stream,
// take a photo of a made-up page, find the words, and "say" them.
// Setup follows ViewModelIntegrationTests in Meta's CameraAccess sample.
//

@testable import SecondMind
import MWDATCamera
import MWDATCore
import MWDATMockDevice
import Observation
import UIKit
import XCTest

@MainActor
final class FakeSpeaker: Speaker {
  private(set) var said: [String] = []
  var isSpeaking: Bool { false }
  func speak(_ text: String, rate: Float) { said.append(text) }
  func stop() {}
}

@MainActor
final class MockGlassesReadingTests: XCTestCase {
  private var mockDevice: MockGlasses?
  private var viewModel: ReadingViewModel?

  override func setUp() async throws {
    try await super.setUp()
    UserDefaults.standard.removeObject(forKey: "reading.autoRead")
    UserDefaults.standard.removeObject(forKey: "reading.rate")
    try? Wearables.configure()
    MockDeviceKit.shared.enable()
    step("mock kit on")
    let device = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    mockDevice = device
    device.powerOn()
    device.don()
    step("glasses paired and worn")
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    step("tearing down")
    viewModel?.stop()
    viewModel = nil
    await MockDeviceKit.shared.disable()
    step("torn down")
    mockDevice = nil
    try await super.tearDown()
  }

  private func videoURL() throws -> URL {
    try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "plant", withExtension: "mp4"),
      "plant.mp4 test video missing"
    )
  }

  /// Sets the mock camera's video and photo off the main thread. The mock
  /// prepares the video with AVFoundation, which can wait on the main thread.
  private func feedCamera(photo: UIImage?) async throws {
    let camera = try XCTUnwrap(mockDevice?.services.camera)
    let video = try videoURL()
    let photoURL = try photo.map { try TestImages.writePNG($0, name: "page-\(UUID().uuidString).png") }
    step("feeding camera")
    await Task.detached {
      camera.setCameraFeed(fileURL: video)
      if let photoURL { camera.setCapturedImage(fileURL: photoURL) }
    }.value
    step("camera fed")
  }

  private func step(_ text: String, _ name: String = #function) {
    NSLog("[SecondMindTest] \(name): \(text)")
  }

  func testReadNowSpeaksWordsFromGlassesPhoto() async throws {
    try await feedCamera(photo: TestImages.page(lines: ["BUS STOP", "ROUTE 22 DOWNTOWN"]))

    let speaker = FakeSpeaker()
    let viewModel = ReadingViewModel(wearables: Wearables.shared, speaker: speaker)
    viewModel.autoRead = false
    self.viewModel = viewModel

    step("waiting for device")
    await observeUntil(timeout: 5) { viewModel.hasActiveDevice }
    step("starting")
    viewModel.start()
    await observeUntil(timeout: 15) { viewModel.isStreaming && viewModel.hasReceivedFirstFrame }
    step("streaming: \(viewModel.status)")
    XCTAssertTrue(viewModel.isStreaming)

    viewModel.readNow()
    await observeUntil(timeout: 45) { viewModel.spokenCount > 0 }
    step("spoke: \(viewModel.lastReadText ?? "nothing")")

    let said = speaker.said.joined(separator: " ").uppercased()
    XCTAssertTrue(said.contains("BUS"), "Said: \(said)")
    XCTAssertTrue(said.contains("DOWNTOWN"), "Said: \(said)")
    XCTAssertEqual(viewModel.lastReadText?.uppercased().contains("STOP"), true)

    // Again repeats the same words without another photo.
    let before = speaker.said.count
    viewModel.sayAgain()
    XCTAssertEqual(speaker.said.count, before + 1)
    XCTAssertEqual(speaker.said.last, speaker.said.first)

    viewModel.stop()
    await observeUntil(timeout: 5) { viewModel.sessionState == .stopped || viewModel.sessionState == .idle }
    XCTAssertFalse(viewModel.isOn)
    XCTAssertFalse(viewModel.showError, "Stopping should not show an error: \(viewModel.errorMessage)")
  }

  /// Live-frame path (practice mode): the plant video has no words.
  func testReadNowFromLiveFrameSaysNoWords() async throws {
    try await feedCamera(photo: nil)

    let speaker = FakeSpeaker()
    let viewModel = ReadingViewModel(wearables: Wearables.shared, speaker: speaker)
    viewModel.autoRead = false
    viewModel.usePhotoCapture = false
    self.viewModel = viewModel

    await observeUntil(timeout: 5) { viewModel.hasActiveDevice }
    viewModel.start()
    await observeUntil(timeout: 15) { viewModel.isStreaming && viewModel.hasReceivedFirstFrame }
    step("streaming, reading frame")
    viewModel.readNow()
    await observeUntil(timeout: 45) { viewModel.spokenCount > 0 }
    step("said: \(speaker.said)")
    XCTAssertEqual(speaker.said.last, "I don't see any words.")
  }

  func testBackgroundingStopsQuietly() async throws {
    try await feedCamera(photo: nil)

    let viewModel = ReadingViewModel(wearables: Wearables.shared, speaker: FakeSpeaker())
    self.viewModel = viewModel

    await observeUntil(timeout: 5) { viewModel.hasActiveDevice }
    viewModel.start()
    await observeUntil(timeout: 15) { viewModel.isStreaming }

    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    await observeUntil(timeout: 5) { !viewModel.isOn && viewModel.streamState == .stopped }
    XCTAssertFalse(viewModel.showError)
  }
}

// MARK: - Helpers (from Meta's CameraAccess sample tests)

private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false
  func tryResume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed else { return false }
    resumed = true
    return true
  }
}

/// Waits for a condition on @Observable objects, waking on changes.
@MainActor
func observeUntil(
  timeout: TimeInterval,
  file: StaticString = #filePath,
  line: UInt = #line,
  condition: @escaping () -> Bool
) async {
  guard !condition() else { return }
  let deadline = ContinuousClock.now + .seconds(timeout)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      XCTFail("Condition not met within \(timeout) seconds", file: file, line: line)
      return
    }
    await withUnsafeContinuation { (cont: UnsafeContinuation<Void, Never>) in
      let once = ResumeOnce()
      withObservationTracking {
        _ = condition()
      } onChange: {
        if once.tryResume() { cont.resume() }
      }
      Task {
        try? await Task.sleep(for: .milliseconds(100))
        if once.tryResume() { cont.resume() }
      }
    }
  }
}
