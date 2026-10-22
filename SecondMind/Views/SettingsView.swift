//
// SettingsView.swift
//
// Keys, voice, Claude model, about me, and where the Obsidian notes go.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Bindable var ai: AISettings
  let listen: ListenViewModel
  @Bindable var graph: GraphModel

  @State private var claudeKey = ""
  @State private var elevenKey = ""
  @State private var pickingVault = false
  @State private var voices: [VoiceInfo] = []

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField(ai.hasKey ? "Claude key saved. Paste to replace." : "Paste Claude API key", text: $claudeKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if !claudeKey.isEmpty {
            Button("Save Claude key") {
              ai.saveClaudeKey(claudeKey)
              claudeKey = ""
            }
          }
          Picker("In the moment", selection: $ai.model) {
            ForEach(ClaudeModel.allCases) { Text($0.label).tag($0) }
          }
          Picker("Notes and Reflect", selection: $ai.notesModel) {
            ForEach(ClaudeModel.allCases) { Text($0.label).tag($0) }
          }
        } header: {
          Text("Claude")
        } footer: {
          Text("Get a key at console.anthropic.com. It's paid by use, separate from a Claude plan. Haiku for quick whispers, Sonnet for the nightly notes and \"How did I do?\".")
        }

        Section {
          SecureField(ai.hasElevenLabsKey ? "ElevenLabs key saved. Paste to replace." : "Paste ElevenLabs API key", text: $elevenKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if !elevenKey.isEmpty {
            Button("Save ElevenLabs key") {
              ai.saveElevenLabsKey(elevenKey)
              elevenKey = ""
            }
          }
          TextField("ElevenLabs voice ID", text: $ai.elevenLabsVoiceID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Toggle("Full-quality voice", isOn: Binding(get: { listen.clearVoice }, set: { listen.clearVoice = $0 }))
          Button("Test the voice") { listen.say("Hey. I'm here whenever you need me.") }
        } header: {
          Text("Voice")
        } footer: {
          Text("ElevenLabs gives a real human voice. Pick one in their Voice Library and paste its ID. Full-quality pauses the mic for a second while I talk, because Bluetooth makes voices sound like a phone call while the mic is on.")
        }

        if !ai.hasElevenLabsKey {
          Section {
            Picker("Backup voice", selection: Binding(
              get: { ai.appleVoiceID ?? VoicePicker.ranked(voices).first?.id ?? "" },
              set: { ai.appleVoiceID = $0 }
            )) {
              ForEach(VoicePicker.ranked(voices)) { Text($0.label).tag($0.id) }
            }
          } footer: {
            Text("Without ElevenLabs, I use the best iPhone voice. Get better ones in iPhone Settings > Accessibility > Spoken Content > Voices > English, then download a Premium voice.")
          }
        }

        Section {
          TextEditor(text: $ai.aboutMe).frame(minHeight: 120)
        } header: {
          Text("About me")
        } footer: {
          Text("How you talk, what you care about, your goals. Every suggestion uses this.")
        }

        Section {
          Button(graph.vaultName.map { "Notes folder: \($0)" } ?? "Choose Obsidian folder") { pickingVault = true }
          Toggle("Delete talks once they're notes", isOn: $graph.deleteAfter)
        } header: {
          Text("Obsidian")
        } footer: {
          Text("Pick your vault folder (in Files, often iCloud Drive > Obsidian). Every night your talks become linked notes for People, Topics, Places, and Lessons.")
        }

        if !ai.savedPlaces.isEmpty {
          Section("Places mentioned") {
            ForEach(ai.savedPlaces, id: \.self) { place in
              Button(place) { Task { await listen.navigator.start(to: place) } }
            }
            .onDelete { ai.savedPlaces.remove(atOffsets: $0) }
          }
        }

        Section("Math") {
          Picker("Answers", selection: $ai.mathStyle) {
            ForEach(MathStyle.allCases) { Text($0.rawValue).tag($0) }
          }
        }
      }
      .navigationTitle("Settings")
      .onAppear { voices = VoicePicker.installed() }
      .fileImporter(isPresented: $pickingVault, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { graph.chooseVault(url) }
      }
    }
  }
}
