//
// Update4Tests.swift
//
// Checks: music and noise filtering, read the room, influence, and likely
// outcomes.
//

@testable import SecondMind
import XCTest

@MainActor
final class Update4Tests: XCTestCase {
  func testSortsSoundsIntoSpeechMusicNoise() {
    let talking = SoundScores.from([("speech", 0.8), ("music", 0.1), ("wind", 0.2)])
    XCTAssertTrue(talking.isSpeech)
    XCTAssertFalse(talking.isMusic)

    let song = SoundScores.from([("music", 0.9), ("singing", 0.7), ("speech", 0.3)])
    XCTAssertFalse(song.isSpeech, "Lyrics aren't someone talking to you")
    XCTAssertTrue(song.isMusic)

    let nature = SoundScores.from([("bird", 0.8), ("wind_noise", 0.6)])
    XCTAssertFalse(nature.isSpeech)
    XCTAssertEqual(nature.noise, 0.8, accuracy: 0.001)
  }

  func testSituationReadDecodesAndBriefs() throws {
    let json = """
      {"user_aim":"get a raise","their_aim":"keep costs down","mood":"calm","upper_hand":"them, they decide",\
      "next_likely":"ask for numbers","turning_point":true,"outcomes":["60% yes if you show results"],\
      "lever":"tie it to the project you saved"}
      """
    let read = try JSONDecoder().decode(SituationRead.self, from: Data(json.utf8))
    XCTAssertTrue(read.turningPoint)
    XCTAssertTrue(read.brief.contains("get a raise"))
    XCTAssertTrue(read.brief.contains("Best honest lever"))
    XCTAssertTrue(read.summary.contains("keep costs down"))
  }

  func testInfluenceStaysHonest() {
    XCTAssertTrue(Prompts.influence.contains("Never lies"))
    XCTAssertTrue(Prompts.situation(influence: true, outcomes: true).contains("Never lies"))
    XCTAssertTrue(Prompts.situation(influence: false, outcomes: false).contains("Keep outcomes empty"))
  }

  func testStylesBringTheirFeatures() {
    let ai = AISettings()
    ai.replyStyle = .presentation
    ai.factCheckMode = .off
    ai.replyStyle = .adaptive
    XCTAssertTrue(ai.influence)
    XCTAssertTrue(ai.outcomes)
    XCTAssertTrue(ai.readRoom)
    XCTAssertEqual(ai.factCheckMode, .smart)
    ai.replyStyle = .balanced
    XCTAssertFalse(ai.influence)
    XCTAssertFalse(ai.outcomes)
    XCTAssertTrue(ai.readRoom)
  }

  func testPresetsSetInfluenceAndOutcomes() {
    let ai = AISettings()
    let listen = ListenViewModel(ai: ai)
    listen.apply(.argument)
    XCTAssertTrue(ai.influence)
    XCTAssertTrue(ai.outcomes)
    listen.apply(.date)
    XCTAssertFalse(ai.influence)
    listen.apply(.allOff)
    XCTAssertFalse(ai.readRoom)
  }
}
