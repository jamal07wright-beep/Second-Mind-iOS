//
// CoachView.swift
//
// Coach mode controls: pick the game, pick the pace, turn it on, face your
// screen. Shows what the glasses see and every call made.
//

import SwiftUI

struct CoachView: View {
  @Bindable var coach: CoachViewModel
  let listen: ListenViewModel
  let reading: ReadingViewModel

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(isOn: Binding(
            get: { coach.isOn },
            set: { on in
              if on {
                reading.stop()
                Task { await coach.start() }
              } else {
                coach.stop()
              }
            }
          )) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Coach").font(.title2.bold())
              Text(coach.status).font(.subheadline).foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 6)

          if let frame = coach.latestFrame, coach.isOn {
            Image(uiImage: frame)
              .resizable()
              .scaledToFit()
              .frame(maxHeight: 200)
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }
          if let call = coach.lastCall {
            Label(call, systemImage: "megaphone.fill").font(.callout.bold())
          }
          if let problem = coach.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
              .font(.callout)
              .foregroundStyle(.orange)
          }
        } footer: {
          Text("Face your screen so the glasses camera can see it. The camera light will be on.")
        }

        Section("What you're doing") {
          Picker("Game", selection: $coach.game) {
            ForEach(CoachGame.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }

        Section {
          Picker("Speed", selection: $coach.pace) {
            ForEach(CoachPace.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          ModePicker(title: "Talking", mode: $coach.talkMode)
          Toggle("Scan shapes, lines and text", isOn: $coach.scanScreen)
        } header: {
          Text("How it coaches")
        } footer: {
          Text("Fast looks every 2.5 seconds. Smart only talks when it matters; Always gives a call every look. Talk to it any time and it answers using your screen. The scan runs free on your phone.")
        }

        if !coach.goals.isEmpty {
          Section("Goals and big moments") {
            ForEach(Array(coach.goals.enumerated()), id: \.offset) { Text($0.element) }
          }
        }

        if !coach.calls.isEmpty || coach.report != nil {
          Section("Coach's report") {
            if let report = coach.report {
              Text(report)
            } else {
              Button {
                Task { await coach.writeReport() }
              } label: {
                HStack {
                  Text("Write the report")
                  Spacer()
                  if coach.isWritingReport { ProgressView() }
                }
              }
              .disabled(coach.isWritingReport)
            }
          }
        }

        if !coach.calls.isEmpty {
          Section("Calls") {
            ForEach(Array(coach.calls.reversed().enumerated()), id: \.offset) { Text($0.element).font(.callout) }
          }
        }
      }
      .navigationTitle("Coach")
    }
  }
}
