//
// Navigator.swift
//
// Directions. When a real plan to go somewhere is heard, a notification
// asks "Directions to X?" and one tap on Yes starts walking directions,
// whispered step by step in the glasses as you move. Places that were only
// mentioned are saved for later.
//

import CoreLocation
import MapKit
import Observation
import UserNotifications

@Observable
@MainActor
final class Navigator: NSObject, CLLocationManagerDelegate {
  /// Speaks into the glasses. Set by Listen mode.
  @ObservationIgnored var say: ((String) -> Void)?

  private(set) var pendingPlace: String?
  private(set) var destination: String?
  private(set) var isNavigating = false

  @ObservationIgnored private let manager = CLLocationManager()
  @ObservationIgnored private var steps: [MKRoute.Step] = []
  @ObservationIgnored private var stepIndex = 0

  static let category = "DIRECTIONS"
  static let yesAction = "DIRECTIONS_YES"

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.activityType = .fitness
    manager.distanceFilter = 8
  }

  static func registerNotificationCategory() {
    let yes = UNNotificationAction(identifier: yesAction, title: "Yes, take me there", options: [.foreground])
    let category = UNNotificationCategory(identifier: Self.category, actions: [yes], intentIdentifiers: [], options: [])
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }

  func requestPermissions() {
    if manager.authorizationStatus == .notDetermined {
      manager.requestWhenInUseAuthorization()
    }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  /// Asks before starting: a notification you can tap from the lock screen.
  func ask(place: String) {
    pendingPlace = place
    let content = UNMutableNotificationContent()
    content.title = "Directions to \(place)?"
    content.body = "Tap Yes and I'll walk you there."
    content.categoryIdentifier = Self.category
    content.userInfo = ["place": place]
    let request = UNNotificationRequest(identifier: "directions", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
    say?("Directions to \(place)? Tap yes on your phone.")
  }

  func confirm() {
    guard let place = pendingPlace else { return }
    pendingPlace = nil
    Task { await start(to: place) }
  }

  func dismissPending() {
    pendingPlace = nil
  }

  func start(to place: String) async {
    do {
      let route = try await walkingRoute(to: place)
      steps = route.steps.filter { !$0.instructions.isEmpty }
      stepIndex = 0
      destination = place
      isNavigating = true
      manager.allowsBackgroundLocationUpdates = true
      manager.showsBackgroundLocationIndicator = true
      manager.startUpdatingLocation()
      let minutes = max(1, Int(route.expectedTravelTime / 60))
      var intro = "\(place) is \(Self.distance(route.distance)), about \(minutes) minutes walking."
      if let first = steps.first { intro += " \(first.instructions)." }
      say?(intro)
    } catch {
      say?("I couldn't find a walking route to \(place).")
    }
  }

  func stop() {
    manager.stopUpdatingLocation()
    isNavigating = false
    destination = nil
    steps = []
  }

  private func walkingRoute(to place: String) async throws -> MKRoute {
    let search = MKLocalSearch.Request()
    search.naturalLanguageQuery = place
    if let here = manager.location?.coordinate {
      search.region = MKCoordinateRegion(center: here, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
    }
    let found = try await MKLocalSearch(request: search).start()
    guard let item = found.mapItems.first else { throw CLError(.geocodeFoundNoResult) }
    let request = MKDirections.Request()
    request.source = .forCurrentLocation()
    request.destination = item
    request.transportType = .walking
    let response = try await MKDirections(request: request).calculate()
    guard let route = response.routes.first else { throw CLError(.geocodeFoundNoResult) }
    return route
  }

  static func distance(_ meters: CLLocationDistance) -> String {
    let formatter = MKDistanceFormatter()
    formatter.units = .imperial
    formatter.unitStyle = .full
    return formatter.string(fromDistance: meters)
  }

  // MARK: - Location updates

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    Task { @MainActor in self.moved(to: location) }
  }

  private func moved(to location: CLLocation) {
    guard isNavigating, stepIndex < steps.count else { return }
    let step = steps[stepIndex]
    let count = step.polyline.pointCount
    guard count > 0 else { return }
    let end = step.polyline.points()[count - 1].coordinate
    let gap = location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    guard gap < 20 else { return }
    stepIndex += 1
    if stepIndex < steps.count {
      let next = steps[stepIndex]
      say?("In \(Self.distance(next.distance)), \(next.instructions).")
    } else {
      say?("You're here.")
      stop()
    }
  }
}
