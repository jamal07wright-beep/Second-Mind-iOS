//
// NotesView.swift
//
// Today's talks waiting to become notes, and the button to turn them into
// your Obsidian graph now instead of waiting for tonight.
//

import SwiftUI

struct NotesView: View {
  @Bindable var graph: GraphModel
  let ai: AISettings
  @State private var talks: [Conversation] = []

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button {
            Task {
              await graph.buildPending(includeToday: true)
              talks = ConversationStore().all()
            }
          } label: {
            HStack {
              Label("Make my notes now", systemImage: "point.3.connected.trianglepath.dotted")
              Spacer()
              if graph.isBuilding { ProgressView() }
            }
          }
          .disabled(graph.isBuilding || talks.isEmpty)
          if !graph.status.isEmpty {
            Text(graph.status).font(.footnote).foregroundStyle(.secondary)
          }
        } footer: {
          Text(graph.vaultName.map { "Notes go to your \($0) folder." }
            ?? "Pick your Obsidian folder in Settings. Until then notes go to Files > On My iPhone > Second-Mind.")
        }

        Section("Waiting to become notes") {
          if talks.isEmpty {
            Text("Nothing yet. Turn on Listen and talk.").foregroundStyle(.secondary)
          }
          ForEach(talks) { talk in
            NavigationLink(value: talk.id) {
              VStack(alignment: .leading, spacing: 2) {
                Text(talk.title)
                Text("\(talk.lines.count) lines").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .onDelete { offsets in
            let store = ConversationStore()
            for index in offsets { store.delete(talks[index].id) }
            talks.remove(atOffsets: offsets)
          }
        }
      }
      .navigationTitle("Notes")
      .navigationDestination(for: UUID.self) { id in
        if let talk = talks.first(where: { $0.id == id }) {
          TalkView(talk: talk, ai: ai)
        }
      }
      .onAppear { talks = ConversationStore().all() }
      .refreshable { talks = ConversationStore().all() }
    }
  }
}

struct TalkView: View {
  @State var talk: Conversation
  let ai: AISettings
  @State private var loading = false
  @State private var error: String?

  var body: some View {
    List {
      Section("Reflect") {
        if let feedback = talk.feedback {
          Text(feedback)
        } else {
          Button {
            Task { await getFeedback() }
          } label: {
            HStack {
              Text("How did I do?")
              Spacer()
              if loading { ProgressView() }
            }
          }
          .disabled(loading)
        }
        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
      }
      if !talk.notes.isEmpty {
        Section("Second-Mind noticed") {
          ForEach(talk.notes, id: \.self) { Text($0) }
        }
      }
      Section("What was said") {
        ForEach(talk.lines) { line in
          VStack(alignment: .leading, spacing: 2) {
            Text(line.speaker == .me ? "Me" : "Them").font(.caption.bold())
              .foregroundStyle(line.speaker == .me ? Color.indigo : Color.green)
            Text(line.text)
          }
        }
      }
    }
    .navigationTitle(talk.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func getFeedback() async {
    loading = true
    defer { loading = false }
    do {
      let reply = try await ai.client.ask(
        system: Prompts.base(aboutMe: ai.aboutMe, goal: ai.goal) + "\n\n" + Prompts.feedback,
        user: "Conversation:\n\(talk.transcript)\n\nNoticed during it: \(talk.notes.joined(separator: "; "))",
        effort: "medium"
      )
      talk.feedback = reply
      try? ConversationStore().save(talk)
    } catch {
      self.error = error.localizedDescription
    }
  }
}
