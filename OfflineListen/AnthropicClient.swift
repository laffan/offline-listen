import Foundation

/// Errors surfaced by the Anthropic Messages API client.
enum AnthropicError: LocalizedError {
    case notConfigured
    case invalidKey
    case http(Int, String)
    case malformedResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No API key configured."
        case .invalidKey:
            return "The API key was rejected. Check that it's correct."
        case .http(let code, let message):
            return "Anthropic API error (\(code)): \(message)"
        case .malformedResponse:
            return "Couldn't read the response from Anthropic."
        case .network(let message):
            return "Network error: \(message)"
        }
    }
}

/// Thin wrapper around the Anthropic Messages API (`POST /v1/messages`). There's
/// no official Swift SDK, so this speaks the REST API directly over URLSession.
/// We use it for two things: verifying a key works, and a single-shot text
/// completion the organizer parses as JSON.
struct AnthropicClient {
    let apiKey: String
    let model: AIModel

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let version = "2023-06-01"

    /// Verifies the key/model by making the smallest possible request. Throws on
    /// any non-success status (notably `.invalidKey` for a 401).
    func verify() async throws {
        _ = try await complete(system: nil,
                               userText: "Reply with the single word: ok",
                               maxTokens: 8)
    }

    /// Sends one user message (optionally with a system prompt) and returns the
    /// concatenated text of the assistant's reply.
    func complete(system: String?, userText: String, maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else { throw AnthropicError.notConfigured }

        var body: [String: Any] = [
            "model": model.apiModelID,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": userText]
            ],
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AnthropicError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AnthropicError.invalidKey }
            throw AnthropicError.http(http.statusCode, Self.errorMessage(from: data))
        }

        return try Self.text(from: data)
    }

    /// Extracts and joins the `text` blocks from a Messages API response body.
    private static func text(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AnthropicError.malformedResponse
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text
    }

    /// Pulls the human-readable message out of an error response body, falling
    /// back to the raw bytes.
    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "unknown error"
    }
}
