//
// SecondMindApp.swift
//
// Entry point. Sets up Meta's glasses SDK once, checks that the phone's
// secure storage works after Sideloadly signing, and forwards Meta AI
// callback links to the SDK.
//
// Based on Meta's CameraAccess sample (Wearables Device Access Toolkit).
//

import MWDATCore
import SwiftUI

@main
struct SecondMindApp: App {
  @State private var connection: GlassesConnection
  @State private var reading: ReadingViewModel
  @State private var practice = PracticeGlasses()
  private let keychainWorks: Bool

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[SecondMind] Failed to configure Wearables SDK: \(error)")
    }
    keychainWorks = KeychainCheck.run()
    let wearables = Wearables.shared
    _connection = State(wrappedValue: GlassesConnection(wearables: wearables))
    _reading = State(wrappedValue: ReadingViewModel(wearables: wearables, speaker: SystemSpeaker()))
  }

  var body: some Scene {
    WindowGroup {
      ContentView(
        connection: connection,
        reading: reading,
        practice: practice,
        keychainWorks: keychainWorks
      )
      .onOpenURL { url in
        // Only Meta AI callback links go to the SDK.
        guard
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else {
          return
        }
        Task {
          do {
            _ = try await Wearables.shared.handleUrl(url)
          } catch {
            connection.showError(error.localizedDescription)
          }
        }
      }
    }
  }
}
