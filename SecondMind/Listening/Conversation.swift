//
// Conversation.swift
//
// A saved conversation: who said what, and Claude's feedback afterward.
// Stays on the phone.
//

import Foundation

struct ConversationLine: Codable, Equatable, Identifiable {
  var id = UUID()
  var time: Date
  var speaker: Talker
  var text: String
}

struct Conversation: Codable, Equatable, Identifiable {
  var id = UUID()
  var started: Date
  var ended: Date?
  var lines: [ConversationLine] = []
  /// Things Second-Mind flagged (fact corrections, mismatches), for Reflect.
  var notes: [String] = []
  var feedback: String?

  var title: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: started)
  }

  /// Plain text for Claude and for sharing: "Me: ..." / "Them: ...".
  var transcript: String {
    lines.map { line in
      let who: String
      switch line.speaker {
      case .me: who = "Me"
      case .them: who = "Them"
      case .nobody: who = "?"
      }
      return "\(who): \(line.text)"
    }
    .joined(separator: "\n")
  }

  /// The last few lines, for quick in-the-moment help.
  func recent(_ count: Int) -> String {
    var copy = self
    copy.lines = Array(lines.suffix(count))
    return copy.transcript
  }
}

/// Saves conversations as JSON files in the app's Documents folder.
struct ConversationStore {
  let folder: URL

  init(folder: URL? = nil) {
    if let folder {
      self.folder = folder
    } else {
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      self.folder = docs.appendingPathComponent("Conversations", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private func url(for id: UUID) -> URL {
    folder.appendingPathComponent("\(id.uuidString).json")
  }

  func save(_ conversation: Conversation) throws {
    try encoder.encode(conversation).write(to: url(for: conversation.id), options: .atomic)
  }

  func all() -> [Conversation] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { try? decoder.decode(Conversation.self, from: Data(contentsOf: $0)) }
      .sorted { $0.started > $1.started }
  }

  func delete(_ id: UUID) {
    try? FileManager.default.removeItem(at: url(for: id))
  }
}
