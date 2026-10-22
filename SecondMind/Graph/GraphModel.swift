//
// GraphModel.swift
//
// Runs the end-of-day Obsidian build: asks Claude for the day's digest,
// writes the notes into the chosen vault folder, then deletes that day's
// raw transcripts so nothing piles up. Any finished day that was missed
// gets built the next time the app opens.
//

import Foundation
import Observation

@Observable
@MainActor
final class GraphModel {
  private(set) var isBuilding = false
  private(set) var status = ""
  private(set) var vaultName: String?

  var deleteAfter: Bool {
    didSet { UserDefaults.standard.set(deleteAfter, forKey: "graph.deleteAfter") }
  }

  @ObservationIgnored private let ai: AISettings
  @ObservationIgnored private let store = ConversationStore()
  private static let bookmarkKey = "graph.vaultBookmark"

  init(ai: AISettings) {
    self.ai = ai
    deleteAfter = UserDefaults.standard.object(forKey: "graph.deleteAfter") == nil
      ? true : UserDefaults.standard.bool(forKey: "graph.deleteAfter")
    vaultName = resolveVault()?.lastPathComponent
  }

  /// Saves the folder picked in Settings so we can write to it later.
  func chooseVault(_ url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    if let data = try? url.bookmarkData() {
      UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
      vaultName = url.lastPathComponent
      status = "Notes will go in \(url.lastPathComponent)."
    } else {
      status = "Couldn't use that folder. Try another."
    }
  }

  private func resolveVault() -> URL? {
    guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
    if stale, let fresh = try? url.bookmarkData() {
      UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
    }
    return url
  }

  /// Without a chosen vault, notes go in the app's folder (Files > On My iPhone > Second-Mind).
  private var fallbackFolder: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Obsidian", isDirectory: true)
  }

  /// Builds every finished day. With `includeToday`, today too.
  func buildPending(includeToday: Bool) async {
    guard !isBuilding else { return }
    guard ai.hasKey else {
      status = "Add your Claude key in Settings to make notes."
      return
    }
    let today = DayGraph.dayName(Date())
    let byDay = Dictionary(grouping: store.all()) { DayGraph.dayName($0.started) }
    let days = byDay.keys.sorted().filter { includeToday || $0 < today }
    guard !days.isEmpty else {
      status = "Nothing new to add."
      return
    }
    isBuilding = true
    defer { isBuilding = false }
    for day in days {
      status = "Making notes for \(day)…"
      do {
        try await build(day: day, conversations: byDay[day] ?? [])
      } catch {
        status = "Notes for \(day) failed: \(error.localizedDescription)"
        return
      }
    }
    status = "Notes done. Open Obsidian to see your graph."
  }

  private func build(day: String, conversations: [Conversation]) async throws {
    let talks = conversations.sorted { $0.started < $1.started }
    let text = talks.map { convo in
      var part = "### Conversation at \(convo.title)\n\(convo.transcript)"
      if !convo.notes.isEmpty { part += "\nSecond-Mind noticed: " + convo.notes.joined(separator: "; ") }
      return part
    }
    .joined(separator: "\n\n")
    guard !text.isEmpty else { return }

    let reply = try await ai.client.ask(
      system: Prompts.base(aboutMe: ai.aboutMe, goal: "") + "\n\n" + Prompts.graph,
      user: "Day: \(day)\n\n\(text)",
      maxTokens: 16_000,
      effort: "medium",
      schema: DayDigest.schema
    )
    let digest = try JSONDecoder().decode(DayDigest.self, from: Data(reply.utf8))

    let vault = resolveVault()
    let base = vault ?? fallbackFolder
    let access = vault?.startAccessingSecurityScopedResource() ?? false
    defer { if access { vault?.stopAccessingSecurityScopedResource() } }

    let files = DayGraph.files(for: digest, day: day) { path in
      try? String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }
    for (path, content) in files {
      let url = base.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try content.write(to: url, atomically: true, encoding: .utf8)
    }

    if deleteAfter {
      for convo in talks { store.delete(convo.id) }
    }
  }
}
