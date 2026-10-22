//
// ContentView.swift
//
// One simple screen: glasses status, Reading controls, practice mode.
// Big buttons, few words.
//

import SwiftUI

struct ContentView: View {
  @Bindable var connection: GlassesConnection
  @Bindable var reading: ReadingViewModel
  @Bindable var practice: PracticeGlasses
  let keychainWorks: Bool

  private var canRead: Bool { connection.isRegistered || practice.isOn }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          if !keychainWorks {
            Notice(
              text: "Phone storage check failed. Reinstall with Sideloadly. If it keeps happening, tell Claude.",
              color: .orange
            )
          }
          if connection.requiresFirmwareUpdate {
            Notice(text: "Your glasses need an update in the Meta AI app.", color: .orange)
          }
          glassesCard
          readingCard
          practiceCard
        }
        .padding()
      }
      .navigationTitle("Second-Mind")
    }
    .alert("Something went wrong", isPresented: $connection.showError) {
      Button("OK") { connection.dismissError() }
    } message: {
      Text(connection.errorMessage)
    }
    .alert("Something went wrong", isPresented: $reading.showError) {
      Button("OK") { reading.dismissError() }
    } message: {
      Text(reading.errorMessage)
    }
    .alert("Allow the glasses camera?", isPresented: $reading.showCameraPermissionPrompt) {
      Button("Open Meta AI") { Task { await reading.confirmCameraPermission() } }
      Button("Not now", role: .cancel) { reading.stop() }
    } message: {
      Text("Meta AI will open so you can say yes. Then come back here.")
    }
  }

  // MARK: - Glasses

  private var glassesCard: some View {
    Card(title: "Glasses") {
      HStack {
        Circle()
          .fill(reading.hasActiveDevice ? Color.green : Color.gray)
          .frame(width: 12, height: 12)
        Text(glassesStatus)
        Spacer()
      }
      if !connection.isRegistered && !practice.isOn {
        BigButton(
          title: connection.isRegistering ? "Connecting…" : "Connect glasses",
          color: .blue,
          disabled: connection.isRegistering
        ) {
          connection.connect()
        }
        Text("Meta AI will open. Say yes, then come back. Developer Mode must be on in Meta AI.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else if connection.isRegistered {
        Button("Disconnect", role: .destructive) { connection.disconnect() }
          .font(.footnote)
      }
    }
  }

  private var glassesStatus: String {
    if practice.isOn { return "Practice glasses (phone camera)" }
    if !connection.isRegistered { return "Not connected yet" }
    return reading.hasActiveDevice ? "Ready" : "Connected. Put them on."
  }

  // MARK: - Reading

  private var readingCard: some View {
    Card(title: "Reading") {
      Text(reading.status)
        .font(.title3)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let frame = reading.latestFrame {
        Image(uiImage: frame)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 220)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }

      BigButton(
        title: reading.isOn ? "Stop reading" : "Start reading",
        color: reading.isOn ? .red : .green,
        disabled: !canRead && !reading.isOn
      ) {
        reading.usePhotoCapture = !practice.isOn
        reading.isOn ? reading.stop() : reading.start()
      }

      if reading.isOn {
        HStack(spacing: 12) {
          SmallButton(title: "Read", systemImage: "text.viewfinder") { reading.readNow() }
          SmallButton(title: "Again", systemImage: "arrow.counterclockwise") { reading.sayAgain() }
          SmallButton(title: "Hush", systemImage: "speaker.slash") { reading.stopTalking() }
        }
      }

      Toggle("Read on its own when words hold still", isOn: $reading.autoRead)

      VStack(alignment: .leading) {
        Text("Speed")
        HStack {
          Image(systemName: "tortoise")
          Slider(value: $reading.speechRate, in: 0.3...0.6)
          Image(systemName: "hare")
        }
      }

      if let text = reading.lastReadText {
        DisclosureGroup("Last thing read") {
          Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  // MARK: - Practice

  private var practiceCard: some View {
    Card(title: "Practice") {
      Toggle(
        "Use the phone camera as pretend glasses",
        isOn: Binding(
          get: { practice.isOn },
          set: { on in
            reading.stop()
            if on {
              practice.turnOn()
            } else {
              Task { await practice.turnOff() }
            }
          }
        )
      )
      if let error = practice.errorMessage {
        Text(error).font(.footnote).foregroundStyle(.red)
      }
    }
  }
}

// MARK: - Pieces

private struct Card<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      content
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}

private struct Notice: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(color.opacity(0.2))
      .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

private struct BigButton: View {
  let title: String
  let color: Color
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.title2.bold())
        .frame(maxWidth: .infinity, minHeight: 56)
    }
    .buttonStyle(.borderedProminent)
    .tint(color)
    .disabled(disabled)
  }
}

private struct SmallButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
  }
}
