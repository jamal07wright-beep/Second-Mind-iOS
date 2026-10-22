//
// DayGraph.swift
//
// Turns a day of conversations into linked Obsidian notes, so the raw
// transcripts can be deleted and what matters keeps growing as a graph:
//
//   Second-Mind/Days/2026-10-22.md      what happened, lessons, links
//   Second-Mind/People/Name.md          what each person said and cares about
//   Second-Mind/Topics/Topic.md         ideas that keep coming up
//   Second-Mind/Places/Place.md         places, plans
//   Second-Mind/Lessons.md              growth log, newest first
//   Second-Mind/Second-Mind Home.md     index of days
//

import Foundation

/// What Claude pulls out of a day. Matches `DayDigest.schema`.
struct DayDigest: Codable, Equatable {
  struct Entry: Codable, Equatable {
    var name: String
    var notes: [String]
  }

  var summary: String
  var wins: [String]
  var lessons: [String]
  var toRemember: [String]
  var people: [Entry]
  var topics: [Entry]
  var places: [Entry]
  var corrections: [String]

  enum CodingKeys: String, CodingKey {
    case summary, wins, lessons, people, topics, places, corrections
    case toRemember = "to_remember"
  }

  /// JSON schema for Claude's structured output.
  static var schema: [String: Any] {
    let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
    let entries: [String: Any] = [
      "type": "array",
      "items": [
        "type": "object",
        "properties": ["name": ["type": "string"], "notes": strings],
        "required": ["name", "notes"],
        "additionalProperties": false,
      ],
    ]
    return [
      "type": "object",
      "properties": [
        "summary": ["type": "string"],
        "wins": strings,
        "lessons": strings,
        "to_remember": strings,
        "people": entries,
        "topics": entries,
        "places": entries,
        "corrections": strings,
      ],
      "required": ["summary", "wins", "lessons", "to_remember", "people", "topics", "places", "corrections"],
      "additionalProperties": false,
    ]
  }
}

enum DayGraph {
  static let root = "Second-Mind"

  static func dayName(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  /// Obsidian-safe file name.
  static func fileName(_ name: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
    let cleaned = name.components(separatedBy: bad).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Unnamed" : String(cleaned.prefix(80))
  }

  /// Builds every file to write. `existing` reads a file already in the vault (nil if new).
  static func files(for digest: DayDigest, day: String, existing: (String) -> String?) -> [String: String] {
    var out: [String: String] = [:]
    let link = { (name: String) in "[[\(fileName(name))]]" }

    // Daily note.
    var daily = "---\ntags: [second-mind, day]\ndate: \(day)\n---\n# \(day)\n\n\(digest.summary)\n"
    func section(_ title: String, _ lines: [String]) {
      guard !lines.isEmpty else { return }
      daily += "\n## \(title)\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
    }
    section("Wins", digest.wins)
    section("Lessons", digest.lessons)
    section("To remember", digest.toRemember)
    section("People", digest.people.map { link($0.name) })
    section("Topics", digest.topics.map { link($0.name) })
    section("Places", digest.places.map { link($0.name) })
    section("Facts corrected", digest.corrections)
    daily += "\nBack to [[Second-Mind Home]]\n"
    out["\(root)/Days/\(day).md"] = daily

    // People, topics, places: one page each, a dated section added per day.
    func addPages(_ entries: [DayDigest.Entry], folder: String, tag: String) {
      for entry in entries {
        let path = "\(root)/\(folder)/\(fileName(entry.name)).md"
        var page = out[path] ?? existing(path) ?? "---\ntags: [second-mind, \(tag)]\n---\n# \(entry.name)\n"
        let header = "## [[\(day)]]"
        guard !page.contains(header) else {
          out[path] = page
          continue
        }
        page += "\n\(header)\n" + entry.notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
        out[path] = page
      }
    }
    addPages(digest.people, folder: "People", tag: "person")
    addPages(digest.topics, folder: "Topics", tag: "topic")
    addPages(digest.places, folder: "Places", tag: "place")

    // Lessons log: newest day on top.
    if !digest.lessons.isEmpty {
      let path = "\(root)/Lessons.md"
      let title = "# Lessons\n\nWhat we're learning, day by day.\n"
      var body = existing(path) ?? title
      if !body.contains("## [[\(day)]]") {
        let entry = "\n## [[\(day)]]\n" + digest.lessons.map { "- \($0)" }.joined(separator: "\n") + "\n"
        if let range = body.range(of: title) {
          body.insert(contentsOf: entry, at: range.upperBound)
        } else {
          body += entry
        }
      }
      out[path] = body
    }

    // Home index.
    let homePath = "\(root)/Second-Mind Home.md"
    var home = existing(homePath) ?? "# Second-Mind Home\n\nMy second brain. Every day links here.\n\n## Days\n"
    if !home.contains("[[\(day)]]") { home += "- [[\(day)]]\n" }
    out[homePath] = home

    return out
  }
}
