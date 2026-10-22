//
// VoiceProfileTests.swift
//
// Checks the saved voice: pitch finding, telling you from others, the
// quiet voice boost, learning words, and the Obsidian round trip.
//

@testable import SecondMind
import XCTest

final class VoiceProfileTests: XCTestCase {
  private func profile() -> VoiceProfile {
    VoiceProfile(
      pitch: 120, pitchLow: 100, pitchHigh: 150,
      quietLevel: -34, normalLevel: -24, loudLevel: -14,
      wordsPerSecond: 3.1, words: "yo what's good bro", made: Date(), updated: Date()
    )
  }

  private func sine(_ hz: Double, rate: Double = 16_000, count: Int = 1_024) -> [Float] {
    (0..<count).map { Float(0.3 * sin(2 * .pi * hz * Double($0) / rate)) }
  }

  func testFindsPitch() throws {
    let found = try XCTUnwrap(PitchDetector.pitch(sine(150), sampleRate: 16_000))
    XCTAssertEqual(found, 150, accuracy: 6)
    XCTAssertNil(PitchDetector.pitch([Float](repeating: 0, count: 1_024), sampleRate: 16_000))
  }

  func testTellsMeFromThem() {
    let me = profile()
    XCTAssertTrue(me.soundsLikeMe(level: -24, pitch: 125))
    XCTAssertFalse(me.soundsLikeMe(level: -24, pitch: 230), "Different pitch is someone else")
    XCTAssertFalse(me.soundsLikeMe(level: -50, pitch: 125), "Too quiet to be my voice in the glasses")

    var detector = TurnDetector()
    detector.profile = me
    for i in 0..<20 { _ = detector.feed(level: -70, at: Double(i) / 10) }
    XCTAssertEqual(detector.classify(-24, pitch: 122), .me)
    XCTAssertEqual(detector.classify(-24, pitch: 220), .them)
    XCTAssertEqual(detector.classify(-52, pitch: nil), .them, "Quiet voices still count as talking")
  }

  func testQuietBoost() {
    XCTAssertEqual(AudioFeed.gain(forLevel: -20), 1, "Loud enough already")
    XCTAssertEqual(AudioFeed.gain(forLevel: -75), 1, "Silence isn't boosted")
    XCTAssertGreaterThan(AudioFeed.gain(forLevel: -45), 3)
    XCTAssertLessThanOrEqual(AudioFeed.gain(forLevel: -60), 6)
  }

  func testLearnsWordsAndCaps() {
    var me = profile()
    me.learn("for real though")
    XCTAssertTrue(me.words.hasSuffix("for real though"))
    me.learn(String(repeating: "word ", count: 2_000))
    XCTAssertLessThanOrEqual(me.words.count, VoiceProfile.wordLimit)
    XCTAssertTrue(me.styleNote.contains("words a second"))
  }

  func testObsidianRoundTrip() throws {
    let me = profile()
    let note = me.obsidianNote()
    XCTAssertTrue(note.contains("# My Voice"))
    let back = try XCTUnwrap(VoiceProfile.from(note: note))
    XCTAssertEqual(back.pitch, me.pitch)
    XCTAssertEqual(back.words, me.words)
  }
}
