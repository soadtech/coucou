#if !APPSTORE
import Foundation
import SwiftUI

// MARK: - ClassChat
// Questions about one past class. The whole transcript plus the notes go in as
// context: an hour of speech is a few tens of thousands of tokens, which fits
// comfortably, so there is no retrieval step to get wrong.

@MainActor
final class ClassChat: ObservableObject {

    struct Message: Identifiable, Sendable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isAnswering = false
    @Published private(set) var error: String?

    private let meta: ClassMeta
    private var context: String?

    init(meta: ClassMeta) {
        self.meta = meta
    }

    func reset() {
        messages = []
        error = nil
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }

        messages.append(Message(role: .user, text: trimmed))
        error = nil
        isAnswering = true
        defer { isAnswering = false }

        guard let context = buildContext() else {
            error = "Esta clase no tiene transcripción todavía."
            return
        }

        let system = """
        Eres el profesor particular de un estudiante de \(meta.language.label.lowercased()) de nivel A2, \
        cuya lengua materna es el español. Responde SIEMPRE en español, claro y breve. \
        El material en \(meta.language.label.lowercased()) va en su idioma. \
        Básate solo en la clase que te doy: si algo no está ahí, dilo en vez de inventarlo. \
        La transcripción viene de reconocimiento automático y tiene errores; si una parte no se entiende, dilo. \
        Sin markdown: texto plano con saltos de línea.
        """

        // The class goes in the first turn; later turns carry only the exchange.
        var payload: [[String: Any]] = []
        for (index, message) in messages.enumerated() {
            let role = message.role == .user ? "user" : "assistant"
            let text = (index == 0 && message.role == .user)
                ? "\(context)\n\nPregunta: \(message.text)"
                : message.text
            payload.append(["role": role, "content": text])
        }

        do {
            let answer = try await ClaudeService.shared.complete(
                system: system, messages: payload, maxTokens: 2048)
            messages.append(Message(role: .assistant, text: answer))
        } catch {
            self.error = error.localizedDescription
            messages.removeLast()   // drop the question that never got answered
        }
    }

    // MARK: Context

    private func buildContext() -> String? {
        if let context { return context }
        guard let transcript = ClassStore.shared.loadTranscript(meta.id),
              !transcript.segments.isEmpty else { return nil }

        var text = """
        Clase: \(meta.title)
        Idioma: \(meta.language.label)
        Fecha: \(ClassRecorder.dateFormatter.string(from: meta.startedAt))
        Duración: \(ClassRecorder.timecode(meta.duration))
        """

        if let notes = ClassStore.shared.load(ClassNotesDoc.self,
                                              from: ClassStore.shared.notesURL(for: meta.id)) {
            text += "\n\nApuntes ya generados de esta clase:\n"
            text += ClassNotesGenerator.renderMarkdown(notes, meta: meta)
        }

        text += "\n\nTranscripción completa (\"Clase\" es el profesor, \"Yo\" el estudiante):\n"
        text += ClassQuickAsk.render(transcript.segments, maxCharacters: 150_000)

        context = text
        return text
    }
}
#endif
