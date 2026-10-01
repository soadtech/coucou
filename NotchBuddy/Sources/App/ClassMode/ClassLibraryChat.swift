#if !APPSTORE
import Foundation
import SwiftUI

// MARK: - ClassLibraryChat
// Questions across every class recorded so far — "¿cuándo usamos el passé
// composé?", "¿qué palabras nuevas vi esta semana?", "¿qué errores repito?".
//
// Context strategy: the notes of every class always go in, because they are
// compact and already distilled. Transcripts are added newest-first until a
// character budget runs out, and the prompt says plainly which ones made it, so
// the model can admit what it cannot see instead of guessing.

@MainActor
final class ClassLibraryChat: ObservableObject {
    static let shared = ClassLibraryChat()

    /// Reuses the app's own ChatMessage so the existing bubbles render it
    /// unchanged — this chat should look exactly like the original one.
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isAnswering = false
    @Published private(set) var error: String?
    /// How many classes the last context covered, for the UI to show.
    @Published private(set) var classCount = 0

    /// Roughly 75k tokens, well inside the model's window and cheap enough to
    /// resend each turn with caching on.
    private let contextBudget = 300_000

    private var cachedContext: String?
    private var cachedAt: Date?

    private init() {}

    func reset() {
        messages = []
        NotificationCenter.default.post(name: .classChatGrew, object: nil)
        error = nil
        cachedContext = nil
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }

        messages.append(ChatMessage(role: .user, content: trimmed))
        NotificationCenter.default.post(name: .classChatGrew, object: nil)
        error = nil
        isAnswering = true
        defer { isAnswering = false }

        guard GeminiService.shared.isConfigured else {
            error = "El chat necesita una API key de Gemini. Configúrala en Settings → Modo Clase."
            messages.removeLast()
            return
        }
        guard let context = buildContext() else {
            error = "Todavía no hay ninguna clase con apuntes o transcripción."
            messages.removeLast()
            return
        }

        let system = """
        Eres el profesor particular de un estudiante de idiomas de nivel A2 cuya lengua materna es el español. \
        Tienes delante todas sus clases grabadas. Responde SIEMPRE en español, claro y breve. \
        El material en el idioma estudiado va en su idioma. \
        Cuando la respuesta venga de una clase concreta, di de cuál y de qué fecha. \
        Básate solo en lo que te doy: si algo no está, dilo en vez de inventarlo. \
        Las transcripciones son automáticas y tienen errores; si una parte no se entiende, dilo. \
        Sin markdown: texto plano con saltos de línea.
        """

        // Gemini has no per-block cache_control; its context caching is a
        // separate API. The library is resent each turn, which its long context
        // and low per-token price make acceptable for now.
        var payload: [GeminiService.Message] = []
        for (index, message) in messages.enumerated() {
            let text = (index == 0 && message.role == .user)
                ? "\(context)\n\nPregunta: \(message.content)"
                : message.content
            payload.append(message.role == .user ? .user(text) : .model(text))
        }

        do {
            let answer = try await GeminiService.shared.complete(
                system: system, messages: payload, maxTokens: 2048)
            messages.append(ChatMessage(role: .assistant, content: answer))
            NotificationCenter.default.post(name: .classChatGrew, object: nil)
        } catch {
            self.error = error.localizedDescription
            messages.removeLast()
        }
    }

    // MARK: - Context

    private func buildContext() -> String? {
        // Rebuilt when a class has been added since it was last assembled.
        if let cachedContext, let cachedAt, Date().timeIntervalSince(cachedAt) < 60 {
            return cachedContext
        }

        let classes = ClassStore.shared.allClasses().filter { $0.isComplete }
        guard !classes.isEmpty else { return nil }
        classCount = classes.count

        var text = "BIBLIOTECA DE CLASES (\(classes.count) en total, de la más reciente a la más antigua)\n"

        // Index first: even for a class whose transcript did not fit, the model
        // knows it exists and can say so.
        text += "\nÍndice:\n"
        for meta in classes {
            text += "- \(meta.title) · \(meta.language.label) · "
            text += "\(ClassRecorder.dateFormatter.string(from: meta.startedAt)) · "
            text += "\(ClassRecorder.timecode(meta.duration))\n"
        }

        // Notes for every class: compact and already the good part.
        for meta in classes {
            guard let notes = ClassStore.shared.load(
                ClassNotesDoc.self, from: ClassStore.shared.notesURL(for: meta.id)) else { continue }
            text += "\n\n=== APUNTES — \(meta.title) ===\n"
            text += ClassNotesGenerator.renderMarkdown(notes, meta: meta)
        }

        // Transcripts newest-first, while there is room.
        var included: [String] = []
        var skipped: [String] = []
        for meta in classes {
            guard let transcript = ClassStore.shared.loadTranscript(meta.id),
                  !transcript.segments.isEmpty else { continue }
            let body = ClassQuickAsk.render(transcript.segments, maxCharacters: 80_000)
            if text.count + body.count < contextBudget {
                text += "\n\n=== TRANSCRIPCIÓN — \(meta.title) ===\n\(body)"
                included.append(meta.title)
            } else {
                skipped.append(meta.title)
            }
        }

        if !skipped.isEmpty {
            text += "\n\nNOTA: por tamaño, de estas clases solo tienes los apuntes, no la transcripción completa: "
            text += skipped.joined(separator: "; ")
            text += ". Si te preguntan por un detalle literal de alguna de ellas, dilo en vez de deducirlo."
        }

        cachedContext = text
        cachedAt = .now
        return text
    }
}
#endif
