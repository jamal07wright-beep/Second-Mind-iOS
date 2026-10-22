//
// AISettings.swift
//
// Keys, model choice, voice, goal, and the Stage 2 switches. Keys go in the
// iPhone keychain, never in plain storage.
//

import Foundation
import Observation
import Security

/// How Best Reply and "help me when I freeze" should sound.
enum ReplyStyle: String, CaseIterable, Identifiable {
  case adaptive = "Adaptive"
  case balanced = "Balanced"
  case flirty = "Intimate / Flirty"
  case presentation = "Presentation"
  case businessCasual = "Business Casual"
  var id: String { rawValue }
}

enum MathStyle: String, CaseIterable, Identifiable {
  case answer = "Just the answer"
  case explain = "Walk me through it"
  var id: String { rawValue }
}

@Observable
@MainActor
final class AISettings {
  // Claude
  /// For quick whispers in the moment: speed matters most.
  var model: ClaudeModel { didSet { put(model.rawValue, "ai.model") } }
  /// For nightly Obsidian notes and "How did I do?": depth matters most.
  var notesModel: ClaudeModel { didSet { put(notesModel.rawValue, "ai.notesModel") } }
  var aboutMe: String { didSet { put(aboutMe, "ai.aboutMe") } }
  /// Goal for the current conversation; every suggestion leans toward it.
  var goal: String { didSet { put(goal, "ai.goal") } }
  private(set) var hasKey: Bool

  // Voice
  var elevenLabsVoiceID: String { didSet { put(elevenLabsVoiceID, "voice.elevenID") } }
  var appleVoiceID: String? { didSet { put(appleVoiceID, "voice.appleID") } }
  private(set) var hasElevenLabsKey: Bool

  // Stage 2 switches
  /// Best Reply (called Debate in the vault notes).
  var debate: Bool { didSet { put(debate, "s2.debate") } }
  var replyStyle: ReplyStyle { didSet { put(replyStyle.rawValue, "s2.replyStyle") } }
  var factCheck: Bool { didSet { put(factCheck, "s2.factCheck") } }
  var consistency: Bool { didSet { put(consistency, "s2.consistency") } }
  var translate: Bool { didSet { put(translate, "s2.translate") } }
  /// Language to listen for in Translate, like "es-US".
  var translateFrom: String { didSet { put(translateFrom, "s2.translateFrom") } }
  var planDetection: Bool { didSet { put(planDetection, "s2.plans") } }
  var math: Bool { didSet { put(math, "s2.math") } }
  var mathStyle: MathStyle { didSet { put(mathStyle.rawValue, "s2.mathStyle") } }
  /// Places mentioned but not planned, kept for later.
  var savedPlaces: [String] { didSet { UserDefaults.standard.set(savedPlaces, forKey: "s2.places") } }

  init() {
    let d = UserDefaults.standard
    func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
    model = ClaudeModel(rawValue: d.string(forKey: "ai.model") ?? "") ?? .haiku
    notesModel = ClaudeModel(rawValue: d.string(forKey: "ai.notesModel") ?? "") ?? .sonnet
    aboutMe = d.string(forKey: "ai.aboutMe") ?? ""
    goal = d.string(forKey: "ai.goal") ?? ""
    elevenLabsVoiceID = d.string(forKey: "voice.elevenID") ?? ElevenLabsClient.defaultVoiceID
    appleVoiceID = d.string(forKey: "voice.appleID")
    debate = flag("s2.debate", false)
    replyStyle = ReplyStyle(rawValue: d.string(forKey: "s2.replyStyle") ?? "") ?? .adaptive
    factCheck = flag("s2.factCheck", false)
    consistency = flag("s2.consistency", false)
    translate = flag("s2.translate", false)
    translateFrom = d.string(forKey: "s2.translateFrom") ?? "es-US"
    planDetection = flag("s2.plans", true)
    math = flag("s2.math", true)
    mathStyle = MathStyle(rawValue: d.string(forKey: "s2.mathStyle") ?? "") ?? .answer
    savedPlaces = d.stringArray(forKey: "s2.places") ?? []
    hasKey = Keychain.read("claude") != nil
    hasElevenLabsKey = Keychain.read("elevenlabs") != nil
  }

  var client: ClaudeClient { ClaudeClient(apiKey: Keychain.read("claude"), model: model) }
  var notesClient: ClaudeClient { ClaudeClient(apiKey: Keychain.read("claude"), model: notesModel) }
  var elevenLabsKey: String? { Keychain.read("elevenlabs") }

  func saveClaudeKey(_ key: String) { hasKey = Keychain.save(key, as: "claude") }
  func saveElevenLabsKey(_ key: String) { hasElevenLabsKey = Keychain.save(key, as: "elevenlabs") }

  private func put(_ value: Any?, _ key: String) {
    UserDefaults.standard.set(value, forKey: key)
  }
}

enum Keychain {
  private static let service = "SecondMind.keys"

  /// Saves (or clears, if empty) a secret. Returns true if one is now stored.
  static func save(_ value: String, as account: String) -> Bool {
    delete(account)
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data(trimmed.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  static func read(_ account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func delete(_ account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
