//
// ListenView.swift
//
// The remote. One switch turns Second-Mind on; one tap on a preset sets
// everything for the situation; each feature also has its own switch,
// grouped so you only touch what you need right now.
//

import SwiftUI

struct ListenView: View {
  @Bindable var listen: ListenViewModel
  @Bindable var ai: AISettings
  let reading: ReadingViewModel
  let coach: CoachViewModel
  @State private var mathProblem = ""

  var body: some View {
    NavigationStack {
      Form {
        mainSection
        presetSection

        if !ai.hasKey {
          Section {
            Label("Add your Claude key in Settings so the smart features can work.", systemImage: "key")
              .foregroundStyle(.orange)
          }
        }

        Section {
          ModePicker(title: "Best Reply", mode: $ai.bestReplyMode)
          if ai.bestReplyMode != .off {
            Picker("Reply style", selection: $ai.replyStyle) {
              ForEach(ReplyStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            if ai.replyStyle == .adaptive {
              Toggle(isOn: $ai.prMode) {
                SwitchLabel(title: "PR", detail: "On camera or watched: every hint stays clip-safe")
              }
            }
            Toggle(isOn: $ai.readRoom) {
              SwitchLabel(title: "Read the room", detail: "Works out what you're going for, what they want, and what's next")
            }
            Toggle(isOn: $ai.influence) {
              SwitchLabel(title: "Influence", detail: "Hints that move them where you want. Honest moves only")
            }
            Toggle(isOn: $ai.outcomes) {
              SwitchLabel(title: "Likely outcomes", detail: "Only at real turning points")
            }
          }
          Toggle("Help me when I freeze", isOn: $listen.helpWhenStuck)
          Toggle("Predict their words", isOn: $ai.predictWords)
          if ai.predictWords {
            Toggle("Whisper the guess too", isOn: $ai.predictSpoken)
          }
        } header: {
          Label("What to say", systemImage: "text.bubble.fill")
        } footer: {
          Text(ai.bestReplyMode == .off ? "" : Self.styleHint(ai.replyStyle)
            + (ai.bestReplyMode == .smart ? " Smart: only when you need it." : " Always: after every line."))
        }

        Section {
          Toggle("Ignore music and noise", isOn: $listen.ignoreNoise)
          Toggle("Boost quiet voices", isOn: $listen.boostQuiet)
          Button(listen.voiceProfile == nil ? "Learn my voice" : "Redo my voice") {
            listen.stop()
            listen.showVoiceSetup = true
          }
        } header: {
          Label("Hearing", systemImage: "waveform")
        } footer: {
          Text(listen.voiceProfile == nil
            ? "Learn my voice once so it can tell you apart from everyone else, even quiet talkers."
            : "Knows your voice. Boost quiet voices helps catch people who talk low or mumble.")
        }

        Section {
          Toggle("Your turn", isOn: $listen.turnBeeps)
          Toggle("Hold on (they were just pausing)", isOn: $listen.holdOnBeep)
          Toggle("Awkward pause", isOn: $listen.awkwardBeep)
          Toggle("I'm talking too long", isOn: $listen.longTalkNudge)
        } header: {
          Label("Timing beeps", systemImage: "metronome.fill")
        }

        Section {
          Toggle("Mood chimes", isOn: $listen.moodChimes)
        } header: {
          Label("Mood", systemImage: "face.smiling")
        } footer: {
          Text("1 chime light, 2 tense, 3 hurt. Only when their mood changes.")
        }

        Section {
          ModePicker(title: "Fact Check", mode: $ai.factCheckMode)
          ModePicker(title: "Consistency", mode: $ai.consistencyMode)
          Toggle("Remember past talks", isOn: $ai.useMemory)
        } header: {
          Label("Facts and memory", systemImage: "checkmark.seal.fill")
        } footer: {
          Text("Remember past talks uses your Obsidian People notes, so it knows the people you talk to.")
        }

        Section {
          Toggle("Translate", isOn: $ai.translate)
          if ai.translate {
            Picker("They speak", selection: $ai.translateFrom) {
              ForEach(Self.languages, id: \.0) { pair in Text(pair.1).tag(pair.0) }
            }
          }
          Toggle("Math (heard in conversation)", isOn: $ai.math)
          HStack {
            TextField("Type a math problem", text: $mathProblem)
              .submitLabel(.go)
              .onSubmit { listen.solveTyped(mathProblem) }
            Button("Solve") { listen.solveTyped(mathProblem) }.disabled(mathProblem.isEmpty)
          }
          if let answer = listen.mathAnswer {
            Text(answer).font(.callout.bold())
          }
          Toggle("Directions", isOn: $ai.planDetection)
        } header: {
          Label("Tools", systemImage: "wrench.and.screwdriver.fill")
        }

        Section("Goal for this talk") {
          TextField("Like: get the job, make up with Jay", text: $ai.goal, axis: .vertical)
        }

        if listen.navigator.pendingPlace != nil || listen.navigator.isNavigating {
          Section("Directions") {
            if let place = listen.navigator.pendingPlace {
              Button("Take me to \(place)") { listen.navigator.confirm() }
            }
            if let place = listen.navigator.destination {
              HStack {
                Text("Walking to \(place)")
                Spacer()
                Button("Stop") { listen.navigator.stop() }
              }
            }
          }
        }
      }
      .navigationTitle("Listen")
      .alert("Something went wrong", isPresented: $listen.showError) {
        Button("OK") { listen.showError = false }
      } message: {
        Text(listen.errorMessage)
      }
    }
  }

  // MARK: - Pieces

  private var mainSection: some View {
    Section {
      Toggle(isOn: Binding(
        get: { listen.isOn },
        set: { on in
          if on {
            reading.stop()
            coach.stop()
            Task { await listen.start() }
          } else {
            listen.stop()
          }
        }
      )) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Second-Mind").font(.title2.bold())
          Text(listen.status).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 6)

      if listen.isOn {
        HStack {
          Circle().fill(dotColor).frame(width: 10, height: 10)
          Text(talkerText).foregroundStyle(.secondary)
          Spacer()
          Button(listen.voiceProfile == nil ? "Learn my voice" : "Redo my voice") {
            listen.stop()
            listen.showVoiceSetup = true
          }
          .font(.footnote)
        }
        if !listen.partial.isEmpty {
          Text(listen.partial).font(.callout).foregroundStyle(.secondary).lineLimit(3)
        }
        if ai.predictWords, let guess = listen.prediction {
          Label(guess, systemImage: "wand.and.stars").font(.callout).foregroundStyle(.indigo)
        }
        if let note = listen.soundNote {
          Label(note, systemImage: "music.note").font(.footnote).foregroundStyle(.secondary)
        }
        if ai.readRoom, let read = listen.situation {
          Label(read.summary, systemImage: "eye").font(.footnote).foregroundStyle(.secondary)
        }
      }
      if let said = listen.lastSaid {
        Label(said, systemImage: "quote.bubble").font(.callout)
      }
      if let problem = listen.problem {
        HStack(alignment: .top) {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
          Spacer()
          Button("OK") { listen.clearProblem() }.font(.footnote)
        }
      }
    } footer: {
      Text("Ask people if they're okay with it before using it around them.")
    }
  }

  private var presetSection: some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(Preset.allCases) { preset in
            Button {
              listen.apply(preset)
            } label: {
              Label(preset.rawValue, systemImage: preset.icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.indigo.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 4)
      }
      .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    } header: {
      Text("Quick setups")
    }
  }

  private var dotColor: Color {
    switch listen.talker {
    case .me: return .indigo
    case .them: return .green
    case .nobody: return .gray.opacity(0.4)
    }
  }

  private var talkerText: String {
    switch listen.talker {
    case .me: return "You're talking"
    case .them: return "They're talking"
    case .nobody: return listen.usingGlassesMic ? "Glasses mic" : "Phone mic"
    }
  }

  static func styleHint(_ style: ReplyStyle) -> String {
    switch style {
    case .adaptive: return "For on the go: reads the room and matches it."
    case .balanced: return "Neutral, friendly, clear."
    case .flirty: return "Playful and warm. Backs off if they're not feeling it."
    case .presentation: return "Professional and persuasive."
    case .businessCasual: return "Relaxed but professional."
    }
  }

  static let languages: [(String, String)] = [
    ("es-US", "Spanish"), ("fr-FR", "French"), ("pt-BR", "Portuguese"), ("ar-SA", "Arabic"),
    ("zh-CN", "Chinese"), ("ko-KR", "Korean"), ("ja-JP", "Japanese"), ("vi-VN", "Vietnamese"),
    ("ru-RU", "Russian"), ("de-DE", "German"), ("it-IT", "Italian"), ("hi-IN", "Hindi"),
  ]
}

/// A switch label with a short line under it.
struct SwitchLabel: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Off / Smart / Always in one row.
struct ModePicker: View {
  let title: String
  @Binding var mode: FeatureMode

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
      Picker(title, selection: $mode) {
        ForEach(FeatureMode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
    .padding(.vertical, 2)
  }
}
