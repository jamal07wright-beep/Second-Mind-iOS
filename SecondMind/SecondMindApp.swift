//
// SecondMindApp.swift
//
// Entry point. Sets up Meta's glasses SDK once, checks that the phone's
// secure storage works after sideload signing, and forwards Meta AI
// callback links to the SDK.
//
// Based on Meta's CameraAccess sample (Wearables Device Access Toolkit).
//

import MWDATCore
import SwiftUI

@main
struct SecondMindApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let keychainWorks: Bool
  private let state: AppState

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[SecondMind] Failed to configure Wearables SDK: \(error)")
    }
    keychainWorks = KeychainCheck.run()
    state = AppState.shared
  }

  var body: some Scene {
    WindowGroup {
      RootView(state: state, keychainWorks: keychainWorks)
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
              state.connection.showError(error.localizedDescription)
            }
          }
        }
    }
  }
}
