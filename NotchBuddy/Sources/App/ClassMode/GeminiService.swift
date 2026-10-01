#if !APPSTORE
import Foundation

// MARK: - GeminiService
// The AI behind Class Mode: notes, the per-class chat and the library chat.
// The key lives in the Keychain like every other secret, and only text is ever
// sent — the audio never leaves the Mac.
//
// Without a key the app still records, transcribes on-device, keeps marks and
// browses history; only the generated parts are unavailable.

@MainActor
final class GeminiService {
    static let shared = GeminiService()

    static let keychainKey = "gemini-api-key"

    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Stored rather than hard-coded: model names change, and a stale constant
    /// would leave the app broken with no way out but a new build.
    var model: String {
        get { UserDefaults.standard.string(forKey: "geminiModel") ?? "gemini-2.5-flash" }
        set { UserDefaults.standard.set(newValue, forKey: "geminiModel") }
    }

    var apiKey: String? {
        let key = KeychainStore.shared.get(Self.keychainKey)
        return (key?.isEmpty == false) ? key : nil
    }

    /// True when the generated features are available at all.
    var isConfigured: Bool { apiKey != nil }

    private init() {}

    // MARK: - Messages

    struct Message: Sendable {
        enum Role: String { case user, model }
        let role: Role
        let text: String

        static func user(_ text: String) -> Message { .init(role: .user, text: text) }
        static func model(_ text: String) -> Message { .init(role: .model, text: text) }
    }

    enum GeminiError: LocalizedError {
        case missingKey
        case http(Int, String)
        case malformed
        case blocked(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Falta la API key de Gemini. Ábrela en Settings → Modo Clase."
            case .http(let code, let message):
                return "Gemini devolvió un error (\(code)): \(message)"
            case .malformed:
                return "Respuesta inesperada de Gemini."
            case .blocked(let reason):
                return "Gemini no respondió (\(reason))."
            }
        }
    }

    // MARK: - Completion

    func complete(system: String,
                  messages: [Message],
                  maxTokens: Int = 2048) async throws -> String {
        guard let key = apiKey else { throw GeminiError.missingKey }
        guard let url = URL(string: "\(endpoint)/\(model):generateContent") else {
            throw GeminiError.malformed
        }

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": messages.map { message in
                ["role": message.role.rawValue, "parts": [["text": message.text]]]
            },
            "generationConfig": [
                "maxOutputTokens": maxTokens,
                "temperature": 0.3,
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Header rather than query string: a key in a URL ends up in logs.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GeminiError.http(status, Self.errorMessage(from: data))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.malformed
        }
        if let feedback = json["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String {
            throw GeminiError.blocked(reason)
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else { throw GeminiError.malformed }
        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            // A candidate without content usually means it hit a limit.
            throw GeminiError.blocked((first["finishReason"] as? String) ?? "sin contenido")
        }

        let text = parts.compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GeminiError.malformed }
        return text
    }

    /// Checks a key before it is saved, so the failure happens in Settings
    /// rather than halfway through generating notes for a real class.
    func validate(key: String) async -> Result<Void, Error> {
        let previous = KeychainStore.shared.get(Self.keychainKey)
        KeychainStore.shared.set(Self.keychainKey, value: key)
        do {
            _ = try await complete(system: "Responde solo con: ok",
                                   messages: [.user("ok")],
                                   maxTokens: 16)
            return .success(())
        } catch {
            if let previous { KeychainStore.shared.set(Self.keychainKey, value: previous) }
            else { KeychainStore.shared.remove(Self.keychainKey) }
            return .failure(error)
        }
    }

    private static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(data: data, encoding: .utf8)?.prefix(200).description ?? "sin detalle"
        }
        return message
    }
}
#endif
