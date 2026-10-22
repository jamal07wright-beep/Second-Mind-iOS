//
// VoiceSetupView.swift
//
// The voice check screen: one line at a time, a big Record button, a live
// level meter, and what it heard.
//

import SwiftUI

struct VoiceSetupView: View {
  @State var model: VoiceSetupModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        if model.done {
          finished
        } else if let take = model.current {
          ProgressView(value: Double(model.step), total: Double(VoiceSetupModel.takes.count))
            .tint(.indigo)
          Text("\(model.step + 1) of \(VoiceSetupModel.takes.count)")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Text(take.instruction)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
          if let line = take.line {
            Text("\u{201C}\(line)\u{201D}")
              .font(.title2.bold())
              .multilineTextAlignment(.center)
              .padding()
              .frame(maxWidth: .infinity)
              .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
          }

          LevelMeter(level: model.level, active: model.isRecording)

          if !model.heard.isEmpty {
            Text(model.heard).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }
          if let problem = model.problem {
            Text(problem).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
          }

          Spacer()

          Button {
            if model.isRecording {
              model.finishTake()
            } else {
              Task { await model.record() }
            }
          } label: {
            Label(model.isRecording ? "Done" : "Record", systemImage: model.isRecording ? "checkmark" : "mic.fill")
              .font(.title2.bold())
              .frame(maxWidth: .infinity, minHeight: 60)
          }
          .buttonStyle(.borderedProminent)
          .tint(model.isRecording ? .green : .indigo)
        }
      }
      .padding(24)
      .navigationTitle("Learn my voice")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.done ? "Close" : "Later") { dismiss() }
        }
      }
    }
    .interactiveDismissDisabled(model.isRecording)
  }

  private var finished: some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundStyle(.green)
      Text("Got your voice").font(.title.bold())
      if let profile = model.profile {
        Text("Pitch about \(Int(profile.pitch)) Hz, \(String(format: "%.1f", profile.wordsPerSecond)) words a second.")
          .foregroundStyle(.secondary)
      }
      Text("Saved for good, including in your Obsidian vault as My Voice. It keeps learning your words as you talk.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button("Done") { dismiss() }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
    }
  }
}

private struct LevelMeter: View {
  let level: Float
  let active: Bool

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.gray.opacity(0.15))
        Capsule()
          .fill(Color.indigo)
          .frame(width: active ? geo.size.width * CGFloat(max(0, min(1, (level + 70) / 60))) : 0)
          .animation(.linear(duration: 0.1), value: level)
      }
    }
    .frame(height: 10)
  }
}
