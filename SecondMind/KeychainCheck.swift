//
// KeychainCheck.swift
//
// Sideloadly re-signs the app with a free Apple ID, which can change the
// app's keychain group. The glasses SDK keeps its login in the keychain, so
// we test a write and read at launch and warn in plain words if it fails.
//

import Foundation
import Security

enum KeychainCheck {
  static func run() -> Bool {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "SecondMind.selftest",
      kSecAttrAccount as String: "check",
    ]
    SecItemDelete(base as CFDictionary)

    var add = base
    add[kSecValueData as String] = Data("ok".utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }

    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    SecItemDelete(base as CFDictionary)
    return status == errSecSuccess && (result as? Data) == Data("ok".utf8)
  }
}
