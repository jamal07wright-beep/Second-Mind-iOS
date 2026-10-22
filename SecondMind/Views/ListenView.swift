//
// ListenView.swift
//
// The remote. One big switch to turn Second-Mind on, then a switch for
// each Stage 2 feature. After that the phone can go in your pocket.
//

import SwiftUI

struct ListenView: View {
  @Bindable var listen: ListenViewModel
  @Bindable var ai: AISettings
  let reading: ReadingViewModel

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(isOn: Binding(
            get: { listen.isOn },
            set: { on in
              if on {
                reading.stop()
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
              if !listen.isCalibrated {
                Button("Learn my voice") { listen.calibrate() }.font(.footnote)
              }
            }
            if !listen.partial.isEmpty {
              Text(listen.partial).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
          }
          if let said = listen.lastSaid {
            Label(said, systemImage: "quote.bubble").font(.callout)
          }
        } footer: {
          Text("Ask people if they're okay with it before using it around them.")
        }

        if !ai.hasKey {
          Section {
            Label("Add your Claude key in Settings so the smart features can work.", systemImage: "key")
              .foregroundStyle(.orange)
          }
        }

        Section("Social Push") {
          Toggle("Timing beeps", isOn: $listen.turnBeeps)
          Toggle("Mood chimes", isOn: $listen.moodChimes)
          Toggle("Help me when I freeze", isOn: $listen.helpWhenStuck)
          Toggle("Nudge if I talk too long", isOn: $listen.longTalkNudge)
        }

        Section {
          Toggle("Debate", isOn: $ai.debate)
          Toggle("Fact Check", isOn: $ai.factCheck)
          Toggle("Consistency Check", isOn: $ai.consistency)
          Toggle("Math", isOn: $ai.math)
          Toggle("Directions", isOn: $ai.planDetection)
        } header: {
          Text("Claude")
        } footer: {
          Text("All quiet unless something's worth hearing.")
        }

        Section {
          Toggle("Translate", isOn: $ai.translate)
          if ai.translate {
            Picker("They speak", selection: $ai.translateFrom) {
              ForEach(Self.languages, id: \.0) { pair in Text(pair.1).tag(pair.0) }
            }
          }
        } footer: {
          if ai.translate && listen.isOn {
            Text("Turn Second-Mind off and on to switch languages.")
          }
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

  static let languages: [(String, String)] = [
    ("es-US", "Spanish"), ("fr-FR", "French"), ("pt-BR", "Portuguese"), ("ar-SA", "Arabic"),
    ("zh-CN", "Chinese"), ("ko-KR", "Korean"), ("ja-JP", "Japanese"), ("vi-VN", "Vietnamese"),
    ("ru-RU", "Russian"), ("de-DE", "German"), ("it-IT", "Italian"), ("hi-IN", "Hindi"),
  ]
}
