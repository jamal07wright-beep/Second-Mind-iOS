//
// Stage2Tests.swift
//
// Checks for Stage 2: turn taking, mood, chimes, math, the Obsidian graph,
// the Claude and ElevenLabs requests, voice ranking, and saved talks.
//

@testable import SecondMind
import AVFoundation
import XCTest

final class TurnDetectorTests: XCTestCase {
  /// Feeds `seconds` of one level at 10 readings a second.
  private func run(_ detector: inout TurnDetector, level: Float, seconds: Double, from start: inout Double) -> [TurnEvent] {
    var events: [TurnEvent] = []
    let steps = Int(seconds * 10)
    for i in 0..<steps {
      events += detector.feed(level: level, at: start + Double(i) / 10)
    }
    start += seconds
    return events
  }

  private func fresh() -> TurnDetector {
    var d = TurnDetector()
    d.myLevel = -20
    return d
  }

  func testClassifiesByLoudness() {
    var d = fresh()
    var t = 0.0
    _ = run(&d, level: -70, seconds: 2, from: &t)  // learn the quiet room
    XCTAssertEqual(d.classify(-18), .me)
    XCTAssertEqual(d.classify(-38), .them)
    XCTAssertEqual(d.classify(-69), .nobody)
  }

  func testYourTurnAfterTheyFinish() {
    var d = fresh()
    var t = 0.0
    _ = run(&d, level: -70, seconds: 2, from: &t)
    XCTAssertTrue(run(&d, level: -38, seconds: 2, from: &t).isEmpty)
    let events = run(&d, level: -70, seconds: 1, from: &t)
    XCTAssertTrue(events.contains(.yourTurn))
    XCTAssertTrue(events.contains { if case .theyFinished = $0 { return true } else { return false } })
  }

  func testShortRemarkIsNotATurn() {
    var d = fresh()
    var t = 0.0
    _ = run(&d, level: -70, seconds: 2, from: &t)
    _ = run(&d, level: -38, seconds: 0.5, from: &t)
    XCTAssertFalse(run(&d, level: -70, seconds: 1, from: &t).contains(.yourTurn))
  }

  func testAwkwardPause() {
    var d = fresh()
    var t = 0.0
    _ = run(&d, level: -70, seconds: 2, from: &t)
    _ = run(&d, level: -38, seconds: 2, from: &t)
    let events = run(&d, level: -70, seconds: 4.5, from: &t)
    XCTAssertTrue(events.contains(.stalled))
  }

  func testHoldOnWhenCuttingInDuringTheirPause() {
    var d = fresh()
    var t = 0.0
    _ = run(&d, level: -70, seconds: 2, from: &t)
    _ = run(&d, level: -38, seconds: 2, from: &t)
    _ = run(&d, level: -70, seconds: 0.3, from: &t)
    XCTAssertTrue(run(&d, level: -18, seconds: 0.5, from: &t).contains(.holdOn))
  }

  func testTalkingLong() {
    var d = fresh()
    d.longTalk = 5
    var t = 0.0
    _ = run(&d, level: -70, seconds: 2, from: &t)
    XCTAssertTrue(run(&d, level: -18, seconds: 6, from: &t).contains(.talkingLong))
  }
}

final class MoodDetectorTests: XCTestCase {
  func testTenseWhenLouderAndHeatedWords() {
    var m = MoodDetector()
    XCTAssertNil(m.theyFinished(averageLevel: -40, duration: 3, text: "so we went to the store", at: 0))
    let mood = m.theyFinished(averageLevel: -30, duration: 3, text: "bro stop seriously that's wrong", at: 10)
    XCTAssertEqual(mood, .tense)
    XCTAssertEqual(mood?.chimeCount, 2)
  }

  func testLightAndHurt() {
    var m = MoodDetector()
    m.cooldown = 0
    XCTAssertEqual(m.theyFinished(averageLevel: -40, duration: 3, text: "lol that's crazy", at: 0), .light)
    XCTAssertEqual(m.theyFinished(averageLevel: -40, duration: 3, text: "I'm just disappointed and sad", at: 5), .hurt)
  }

  func testOnlyChimesOnChange() {
    var m = MoodDetector()
    m.cooldown = 0
    XCTAssertEqual(m.theyFinished(averageLevel: -40, duration: 3, text: "haha nice", at: 0), .light)
    XCTAssertNil(m.theyFinished(averageLevel: -40, duration: 3, text: "lol funny", at: 5))
  }
}

final class ChimeTests: XCTestCase {
  func testMoodChimeCounts() {
    XCTAssertEqual(Chime.mood(.light).notes.count, 1)
    XCTAssertEqual(Chime.mood(.tense).notes.count, 2)
    XCTAssertEqual(Chime.mood(.hurt).notes.count, 3)
    XCTAssertTrue(Chime.mood(.light).notes.allSatisfy(\.bell))
    XCTAssertFalse(Chime.yourTurn.notes.contains(where: \.bell))
  }

  func testSamplesAreQuietAndFilled() {
    let samples = Chime.awkwardPause.samples()
    XCTAssertGreaterThan(samples.count, Int(0.2 * Chime.sampleRate))
    XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 1, Chime.volume + 0.001)
    let format = AVAudioFormat(standardFormatWithSampleRate: Chime.sampleRate, channels: 1)!
    XCTAssertEqual(Int(Chime.yourTurn.buffer(format: format)?.frameLength ?? 0), Chime.yourTurn.frameCount)
  }
}

final class MathEngineTests: XCTestCase {
  func testCalculator() {
    XCTAssertEqual(MathEngine.evaluate("(18/100)*64"), 11.52)
    XCTAssertEqual(MathEngine.evaluate("7/2"), 3.5)
    XCTAssertEqual(MathEngine.evaluate("2+3*4"), 14)
    XCTAssertEqual(MathEngine.evaluate("-(2+3)"), -5)
    XCTAssertEqual(MathEngine.evaluate("120 / 4"), 30)
  }

  func testRejectsUnsafeOrBroken() {
    XCTAssertNil(MathEngine.evaluate("1++"))
    XCTAssertNil(MathEngine.evaluate("5/0"))
    XCTAssertNil(MathEngine.evaluate("(2+3"))
    XCTAssertNil(MathEngine.evaluate("system('x')"))
    XCTAssertNil(MathEngine.evaluate(""))
  }

  func testSpokenAndDetection() {
    XCTAssertEqual(MathEngine.spoken(14), "14")
    XCTAssertEqual(MathEngine.spoken(11.5234), "11.52")
    XCTAssertTrue(MathEngine.looksLikeMath("what's 18 percent of 64"))
    XCTAssertTrue(MathEngine.looksLikeMath("split 120 between 4 of us"))
    XCTAssertFalse(MathEngine.looksLikeMath("see you later"))
  }
}

final class DayGraphTests: XCTestCase {
  private let digest = DayDigest(
    summary: "Talked to Jay about the job.",
    wins: ["Asked good questions"],
    lessons: ["Pause before answering"],
    toRemember: ["Jay's interview is Friday"],
    people: [.init(name: "Jay", notes: ["Starting at Amazon"])],
    topics: [.init(name: "Jobs", notes: ["Warehouse pays 21 an hour"])],
    places: [.init(name: "Lexington Market", notes: ["Meeting there Saturday"])],
    corrections: []
  )

  func testBuildsLinkedNotes() {
    let files = DayGraph.files(for: digest, day: "2026-10-22") { _ in nil }
    let daily = files["Second-Mind/Days/2026-10-22.md"] ?? ""
    XCTAssertTrue(daily.contains("[[Jay]]"))
    XCTAssertTrue(daily.contains("[[Lexington Market]]"))
    XCTAssertTrue(daily.contains("[[Second-Mind Home]]"))
    XCTAssertTrue(files["Second-Mind/People/Jay.md"]?.contains("## [[2026-10-22]]") == true)
    XCTAssertTrue(files["Second-Mind/Lessons.md"]?.contains("Pause before answering") == true)
    XCTAssertTrue(files["Second-Mind/Second-Mind Home.md"]?.contains("- [[2026-10-22]]") == true)
  }

  func testAppendsToExistingPagesOnce() {
    let existing = "---\ntags: [second-mind, person]\n---\n# Jay\n\n## [[2026-10-21]]\n- Likes ball\n"
    let read: (String) -> String? = { $0.hasSuffix("Jay.md") ? existing : nil }
    var files = DayGraph.files(for: digest, day: "2026-10-22", existing: read)
    let page = files["Second-Mind/People/Jay.md"] ?? ""
    XCTAssertTrue(page.contains("Likes ball"))
    XCTAssertTrue(page.contains("Starting at Amazon"))
    files = DayGraph.files(for: digest, day: "2026-10-22") { $0.hasSuffix("Jay.md") ? page : nil }
    XCTAssertEqual(files["Second-Mind/People/Jay.md"]?.components(separatedBy: "## [[2026-10-22]]").count, 2)
  }

  func testSafeFileNamesAndDecoding() throws {
    XCTAssertEqual(DayGraph.fileName("AC/DC: live?"), "AC DC  live")
    let json = """
      {"summary":"s","wins":[],"lessons":[],"to_remember":["x"],"people":[],"topics":[],"places":[],"corrections":[]}
      """
    let decoded = try JSONDecoder().decode(DayDigest.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.toRemember, ["x"])
  }
}

final class RequestTests: XCTestCase {
  func testClaudeRequestShape() throws {
    let client = ClaudeClient(apiKey: "test-key", model: .opus)
    let request = try client.makeRequest(system: "sys", user: "hi", maxTokens: 100, effort: "low", webSearch: true)
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
    XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
    XCTAssertEqual(((body["tools"] as? [[String: Any]])?.first)?["type"] as? String, "web_search_20260209")
    XCTAssertNil(body["thinking"], "Opus 5.5 thinking can't be disabled; don't send it")
  }

  func testClaudeNeedsKey() {
    XCTAssertThrowsError(try ClaudeClient(apiKey: nil).makeRequest(system: "", user: "", maxTokens: 1, effort: "low"))
  }

  func testClaudeReplyParsing() throws {
    let ok = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":" Hi there "}],"stop_reason":"end_turn"}"#
    XCTAssertEqual(try ClaudeClient.parseReply(Data(ok.utf8)), "Hi there")
    let refused = #"{"content":[],"stop_reason":"refusal"}"#
    XCTAssertThrowsError(try ClaudeClient.parseReply(Data(refused.utf8)))
  }

  func testElevenLabsRequest() throws {
    let request = try ElevenLabsClient(apiKey: "k", voiceID: "abc").makeRequest(text: "hello")
    XCTAssertEqual(request.url?.path, "/v1/text-to-speech/abc")
    XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "k")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["text"] as? String, "hello")
  }
}

final class VoiceAndStoreTests: XCTestCase {
  func testPrefersPremiumEnglish() {
    let voices = [
      VoiceInfo(id: "a", name: "Fred", language: "en-US", quality: .standard, isNovelty: false),
      VoiceInfo(id: "b", name: "Zoe", language: "en-US", quality: .premium, isNovelty: false),
      VoiceInfo(id: "c", name: "Bells", language: "en-US", quality: .premium, isNovelty: true),
      VoiceInfo(id: "d", name: "Amelie", language: "fr-FR", quality: .premium, isNovelty: false),
    ]
    XCTAssertEqual(VoicePicker.choose(voices, preferred: nil)?.id, "b")
    XCTAssertEqual(VoicePicker.choose(voices, preferred: "a")?.id, "a")
    XCTAssertEqual(VoicePicker.ranked(voices).map(\.id), ["b", "a"])
  }

  func testSavesAndLoadsTalks() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = ConversationStore(folder: folder)
    var talk = Conversation(started: Date())
    talk.lines = [ConversationLine(time: Date(), speaker: .them, text: "Yo"), ConversationLine(time: Date(), speaker: .me, text: "Wassup")]
    talk.notes = ["Fact check: it was 1997"]
    try store.save(talk)
    let loaded = store.all()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.transcript, "Them: Yo\nMe: Wassup")
    store.delete(talk.id)
    XCTAssertTrue(store.all().isEmpty)
  }

  @MainActor
  func testLineCues() {
    XCTAssertTrue(ListenViewModel.hasClaim("He was born in 1997"))
    XCTAssertFalse(ListenViewModel.hasClaim("what's good"))
    XCTAssertTrue(ListenViewModel.mentionsPlace("let's go to Lexington Market at 5"))
    XCTAssertFalse(ListenViewModel.mentionsPlace("I'm tired"))
  }
}
