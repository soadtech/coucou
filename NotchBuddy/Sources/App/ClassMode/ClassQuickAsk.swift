#if !APPSTORE
import Foundation
import SwiftUI

// MARK: - ClassQuickAsk
// "¿Qué ha dicho sobre el passé composé?" — asked mid-class, answered from the
// transcript so far. Only text is sent to the API; the audio never leaves
// the Mac.

@MainActor
final class ClassQuickAsk: ObservableObject {
    static let shared = ClassQuickAsk()

    @Published private(set) var question: String?
    @Published private(set) var answer: String?
    @Published private(set) var isAsking = false
    @Published private(set) var error: String?

    private init() {}

    func reset() {
        question = nil; answer = nil; error = nil; isAsking = false
    }

    func ask(_ text: String, segments: [TranscriptSegment], language: ClassLanguage) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        question = trimmed
        answer = nil
        error = nil
        isAsking = true
        defer { isAsking = false }

        guard !segments.isEmpty else {
            error = "Todavía no hay nada transcrito de esta clase."
            return
        }

        // A class is short enough to send whole; the tail is what a mid-class
        // question is almost always about, so it is what gets kept if we have
        // to trim.
        let transcript = Self.render(segments, maxCharacters: 60_000)

        let system = """
        Eres el asistente de un estudiante de \(language.label.lowercased()) de nivel A2. \
        Responde SIEMPRE en español, claro y breve, como se lo explicarías a alguien que está empezando. \
        Básate solo en la transcripción de la clase que te doy: si la respuesta no está ahí, dilo en vez de inventarla. \
        Sin markdown: texto plano con saltos de línea.
        """

        let prompt = """
        Transcripción de la clase hasta ahora ("Clase" es el profesor, "Yo" es el estudiante):

        \(transcript)

        Pregunta del estudiante: \(trimmed)
        """

        do {
            answer = try await ClaudeService.shared.complete(
                system: system,
                messages: [["role": "user", "content": prompt]],
                maxTokens: 1024)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Transcript as plain text, keeping the most recent part if it is too long.
    static func render(_ segments: [TranscriptSegment], maxCharacters: Int) -> String {
        var lines: [String] = []
        for segment in segments {
            let who = segment.speaker == .clase ? "Clase" : "Yo"
            lines.append("[\(ClassRecorder.timecode(segment.start))] \(who): \(segment.text)")
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters {
            text = "…(principio recortado)…\n" + String(text.suffix(maxCharacters))
        }
        return text
    }
}
#endif
