//
// GlassesConnection.swift
//
// Tracks whether the app is registered with Meta AI and which glasses are
// around. Adapted from WearablesViewModel in Meta's CameraAccess sample.
//

import MWDATCore
import Observation
import SwiftUI

@Observable
@MainActor
final class GlassesConnection {
  var devices: [DeviceIdentifier]
  var registrationState: RegistrationState
  var showError: Bool = false
  var errorMessage: String = ""
  var requiresFirmwareUpdate: Bool = false

  var isRegistered: Bool { registrationState == .registered }
  var isRegistering: Bool { registrationState == .registering }

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?
  @ObservationIgnored private var compatibility: [DeviceIdentifier: Compatibility] = [:]
  @ObservationIgnored private var compatibilityTokens: [DeviceIdentifier: AnyListenerToken] = [:]

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.registrationState = wearables.registrationState

    registrationTask = Task { [weak self] in
      for await state in wearables.registrationStateStream() {
        self?.registrationState = state
      }
    }
    deviceStreamTask = Task { [weak self] in
      for await devices in wearables.devicesStream() {
        self?.devices = devices
        self?.watchCompatibility(devices)
      }
    }
  }

  func connect() {
    guard registrationState != .registering else { return }
    Task { @MainActor in
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func disconnect() {
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch let error as UnregistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func openFirmwareUpdate() async {
    do {
      try await wearables.openFirmwareUpdate()
    } catch {
      showError(error.description)
    }
  }

  func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func dismissError() {
    showError = false
  }

  private func watchCompatibility(_ devices: [DeviceIdentifier]) {
    let present = Set(devices)
    compatibilityTokens = compatibilityTokens.filter { present.contains($0.key) }
    compatibility = compatibility.filter { present.contains($0.key) }

    for deviceId in devices where compatibilityTokens[deviceId] == nil {
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }
      compatibility[deviceId] = device.compatibility()
      let name = device.nameOrId()
      compatibilityTokens[deviceId] = device.addCompatibilityListener { [weak self] value in
        Task { @MainActor [weak self] in
          self?.compatibilityChanged(value, deviceId: deviceId, name: name)
        }
      }
    }
    updateFirmwareFlag()
  }

  private func compatibilityChanged(_ value: Compatibility, deviceId: DeviceIdentifier, name: String) {
    compatibility[deviceId] = value
    updateFirmwareFlag()
    if value == .deviceUpdateRequired {
      showError("\(name) needs an update to work with this app.")
    }
  }

  private func updateFirmwareFlag() {
    requiresFirmwareUpdate = compatibility.values.contains(.deviceUpdateRequired)
  }
}
