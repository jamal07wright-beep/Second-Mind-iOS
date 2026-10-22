//
// PracticeGlasses.swift
//
// Practice mode: Meta's mock glasses, fed by the phone's back camera, so
// Reading can be tried without wearing the real glasses.
//

import MWDATMockDevice
import Observation

@Observable
@MainActor
final class PracticeGlasses {
  private(set) var isOn = false
  var errorMessage: String?

  @ObservationIgnored private var device: MockGlasses?

  func turnOn() {
    guard !isOn else { return }
    do {
      MockDeviceKit.shared.enable()
      let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
      glasses.powerOn()
      glasses.unfold()
      glasses.don()
      glasses.services.camera.setCameraFeed(cameraFacing: .back)
      device = glasses
      isOn = true
      errorMessage = nil
    } catch {
      errorMessage = "Practice mode didn't start: \(error.localizedDescription)"
    }
  }

  func turnOff() async {
    guard isOn else { return }
    await MockDeviceKit.shared.disable()
    device = nil
    isOn = false
  }
}
