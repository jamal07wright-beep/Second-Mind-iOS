//
// Update3Tests.swift
//
// Checks for the update after Stage 2: Smart/Always modes, presets,
// sentence prediction prompts, Coach mode, and pictures sent to Claude.
//

@testable import SecondMind
import UIKit
import XCTest

@MainActor
final class Update3Tests: XCTestCase {
  func testSmartAndAlwaysPrompts() {
    XCTAssertTrue(Prompts.bestReply(.adaptive, mode: .smart).contains(Prompts.quiet))
    XCTAssertTrue(Prompts.bestReply(.adaptive, mode: .always).contains("Always give one"))
    XCTAssertTrue(Prompts.factCheck(.always).contains("That's right"))
    XCTAssertFalse(Prompts.factCheck(.smart).contains("That's right"))
    XCTAssertTrue(Prompts.memory("Jay likes ball").contains("Jay likes ball"))
  }

  func testPresetsSetTheRightSwitches() {
    let ai = AISettings()
    let listen = ListenViewModel(ai: ai)
    listen.apply(.interview)
    XCTAssertEqual(ai.bestReplyMode, .always)
    XCTAssertEqual(ai.replyStyle, .presentation)
    XCTAssertTrue(listen.longTalkNudge)
    listen.apply(.date)
    XCTAssertEqual(ai.replyStyle, .flirty)
    listen.apply(.allOff)
    XCTAssertEqual(ai.bestReplyMode, .off)
    XCTAssertFalse(listen.turnBeeps)
    XCTAssertFalse(ai.math)
    listen.apply(.social)
    XCTAssertEqual(ai.bestReplyMode, .smart)
    XCTAssertTrue(listen.helpWhenStuck)
  }

  func testTypedMathNeedsNoClaudeForArithmetic() {
    let listen = ListenViewModel(ai: AISettings())
    listen.solveTyped("(18/100)*64")
    XCTAssertEqual(listen.mathAnswer, "11.52")
  }

  func testCoachReplyDecodesAndPromptsDiffer() throws {
    let json = #"{"say":"Hit the space on the right","notes":"They press high","event":"goal_for","rating":"8/10 great through ball"}"#
    let reply = try JSONDecoder().decode(CoachReply.self, from: Data(json.utf8))
    XCTAssertEqual(reply.event, "goal_for")
    let guides = CoachGame.allCases.map { CoachPrompts.guide($0) }
    XCTAssertEqual(Set(guides).count, CoachGame.allCases.count)
    XCTAssertTrue(CoachPrompts.guide(.fifa).contains("4-3-3"))
    XCTAssertTrue(CoachPrompts.system(game: .fifa, mode: .smart, aboutMe: "").contains("leave say empty"))
    XCTAssertLessThan(CoachPace.fast.interval, CoachPace.normal.interval)
  }

  func testFramesShrinkToJPEG() throws {
    let big = UIGraphicsImageRenderer(size: CGSize(width: 2_000, height: 1_000)).image { context in
      UIColor.green.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
    }
    let data = try XCTUnwrap(CoachViewModel.jpeg(big))
    let back = try XCTUnwrap(UIImage(data: data))
    XCTAssertLessThanOrEqual(max(back.size.width, back.size.height), 1_024)
  }

  func testPicturesGoToClaudeBeforeText() throws {
    let request = try ClaudeClient(apiKey: "k", model: .haiku)
      .makeRequest(system: "s", user: "look", maxTokens: 10, effort: "low", images: [Data([1, 2, 3])])
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    let message = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first)
    let content = try XCTUnwrap(message["content"] as? [[String: Any]])
    XCTAssertEqual(content.first?["type"] as? String, "image")
    XCTAssertEqual(content.last?["text"] as? String, "look")
  }
}
