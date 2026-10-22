//
// AppState.swift
//
// One shared place for the long-lived parts, so notifications (like the
// Directions "Yes" button) can reach them even from the lock screen.
//

import MWDATCore
import SwiftUI
import UserNotifications

@MainActor
final class AppState {
  static let shared = AppState()

  let ai = AISettings()
  let connection: GlassesConnection
  let reading: ReadingViewModel
  let practice = PracticeGlasses()
  let listen: ListenViewModel
  let graph: GraphModel

  private init() {
    let wearables = Wearables.shared
    connection = GlassesConnection(wearables: wearables)
    reading = ReadingViewModel(wearables: wearables, speaker: SystemSpeaker())
    listen = ListenViewModel(ai: ai)
    graph = GraphModel(ai: ai)
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    Navigator.registerNotificationCategory()
    return true
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let action = response.actionIdentifier
    Task { @MainActor in
      let navigator = AppState.shared.listen.navigator
      if action == Navigator.yesAction || action == UNNotificationDefaultActionIdentifier {
        navigator.confirm()
      } else {
        navigator.dismissPending()
      }
      completionHandler()
    }
  }

  /// Show the "Directions to X?" banner even when the app is open.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
