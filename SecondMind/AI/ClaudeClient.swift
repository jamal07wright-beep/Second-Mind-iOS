//
// ClaudeClient.swift
//
// Talks to Claude through Anthropic's Messages API. Swift has no official
// Anthropic SDK, so this is a small raw HTTP client.
//

import Foundation

enum ClaudeModel: String, CaseIterable, Identifiable {
  case opus = "claude-opus-5-5"
  case sonnet = "claude-sonnet-5-5"
  case haiku = "claude-haiku-5-5"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .opus: return "Claude Opus 5.5 (smartest)"
    case .sonnet: return "Claude Sonnet 5.5 (balanced)"
    case .haiku: return "Claude Haiku 5.5 (fastest, cheapest)"
    }
  }
}

enum ClaudeError: LocalizedError {
  case noKey
  case http(Int, String)
  case refused
  case empty

  var errorDescription: String? {
    switch self {
    case .noKey: return "Add your Claude API key in Settings first."
    case .http(let code, let message): return "Claude error \(code): \(message)"
    case .refused: return "Claude declined to answer that."
    case .empty: return "Claude sent back nothing."
    }
  }
}

struct ClaudeClient {
  var apiKey: String?
  var model: ClaudeModel = .opus
  var session: URLSession = .shared

  static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

  /// Builds the HTTP request. Separate so tests can check it without a network.
  func makeRequest(
    system: String,
    user: String,
    maxTokens: Int,
    effort: String,
    webSearch: Bool = false,
    schema: [String: Any]? = nil
  ) throws -> URLRequest {
    guard let apiKey, !apiKey.isEmpty else { throw ClaudeError.noKey }
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")

    var outputConfig: [String: Any] = ["effort": effort]
    if let schema {
      // Structured output: the reply is JSON matching this schema.
      outputConfig["format"] = ["type": "json_schema", "schema": schema]
    }
    var body: [String: Any] = [
      "model": model.rawValue,
      "max_tokens": maxTokens,
      "system": system,
      "messages": [["role": "user", "content": user]],
      "output_config": outputConfig,
    ]
    if webSearch {
      // Haiku only supports the basic search tool.
      let type = model == .haiku ? "web_search_20250305" : "web_search_20260209"
      body["tools"] = [["type": type, "name": "web_search", "max_uses": 2]]
    }
    // If Opus or Sonnet declines on a safety check, let Anthropic retry on a
    // fallback model instead of failing.
    if model != .haiku {
      request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
      body["fallbacks"] = "default"
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  /// Pulls the reply text out of a Messages API response.
  static func parseReply(_ data: Data) throws -> String {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ClaudeError.empty
    }
    if json["stop_reason"] as? String == "refusal" { throw ClaudeError.refused }
    let blocks = json["content"] as? [[String: Any]] ?? []
    let text = blocks
      .filter { $0["type"] as? String == "text" }
      .compactMap { $0["text"] as? String }
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw ClaudeError.empty }
    return text
  }

  static func parseError(_ data: Data) -> String {
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let error = json?["error"] as? [String: Any]
    return error?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "unknown"
  }

  func ask(
    system: String,
    user: String,
    maxTokens: Int = 2_000,
    effort: String = "low",
    webSearch: Bool = false,
    schema: [String: Any]? = nil
  ) async throws -> String {
    let request = try makeRequest(
      system: system,
      user: user,
      maxTokens: maxTokens,
      effort: effort,
      webSearch: webSearch,
      schema: schema
    )
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw ClaudeError.http(status, Self.parseError(data)) }
    return try Self.parseReply(data)
  }
}
