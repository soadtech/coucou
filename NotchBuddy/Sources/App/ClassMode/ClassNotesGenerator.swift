#if !APPSTORE
import Foundation
import SwiftUI

// MARK: - ClassNotesGenerator
// Turns a finished class into study notes, using the Anthropic key already in
// the Keychain. Only text is sent: the transcript and the marks. The audio
// never leaves the Mac.

@MainActor
final class ClassNotesGenerator: ObservableObject {
    static let shared = ClassNotesGenerator()

    enum State: Equatable {
        case idle
        case generating(classId: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private init() {}

    var isGenerating: Bool {
        if case .generating = state { return true }
        return false
    }

    /// Generates notes for a class and writes notes.json + notes.md.
    @discardableResult
    func generate(for meta: ClassMeta) async -> ClassNotesDoc? {
        guard !isGenerating else { return nil }
        state = .generating(classId: meta.id)
        defer { if isGenerating { state = .idle } }

        guard GeminiService.shared.isConfigured else {
            state = .failed("Los apuntes necesitan una API key de Gemini. Configúrala en Settings → Modo Clase.")
            return nil
        }
        guard let transcript = ClassStore.shared.loadTranscript(meta.id),
              !transcript.segments.isEmpty else {
            state = .failed("Esta clase no tiene transcripción, así que no hay nada de lo que sacar apuntes.")
            return nil
        }
        let marks = ClassStore.shared.loadMarks(meta.id)?.marks ?? []

        let body = Self.prompt(meta: meta, segments: transcript.segments, marks: marks)
        do {
            let raw = try await GeminiService.shared.complete(
                system: Self.systemPrompt(language: meta.language),
                messages: [.user(body)],
                maxTokens: 8192)

            var doc = try Self.parse(raw, classId: meta.id)
            doc.model = GeminiService.shared.model
            doc.generatedAt = .now
            doc.marks = Self.attachExcerpts(doc.marks, marks: marks, segments: transcript.segments)

            try ClassStore.shared.save(doc, to: ClassStore.shared.notesURL(for: meta.id))
            try Self.renderMarkdown(doc, meta: meta)
                .write(to: ClassStore.shared.notesMarkdownURL(for: meta.id),
                       atomically: true, encoding: .utf8)

            state = .idle
            return doc
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Prompt

    private static func systemPrompt(language: ClassLanguage) -> String {
        """
        Eres el profesor particular de un estudiante de \(language.label.lowercased()) de nivel A2, cuya lengua materna es el español.

        A partir de la transcripción de su clase, prepara sus apuntes.

        Reglas:
        - TODAS las explicaciones van en español, sencillas y concretas, como para alguien de nivel A2. Nada de metalenguaje complicado.
        - El material en \(language.label.lowercased()) (palabras, ejemplos, frases, correcciones) va en su idioma original.
        - En la transcripción, "Clase" es el profesor y "Yo" es el estudiante.
        - Usa SOLO lo que aparece en la transcripción. No inventes vocabulario ni reglas que no se trataron.
        - La transcripción viene de reconocimiento automático y tiene errores. Si algo no se entiende, omítelo en vez de adivinar.
        - Si una sección no tiene contenido real, devuélvela vacía. Es correcto y preferible a rellenarla.

        Responde ÚNICAMENTE con JSON válido, sin markdown ni texto alrededor, con esta forma exacta:
        {
          "summary": "resumen de la clase en español, 3-6 frases",
          "vocabulary": [{"term":"", "translation":"", "example":"", "exampleTranslation":""}],
          "grammar": [{"title":"", "explanation":"", "examples":[""]}],
          "phrases": [{"phrase":"", "meaning":"", "context":""}],
          "corrections": [{"said":"", "corrected":"", "explanation":"", "at": 0}],
          "marks": [{"at": 0, "explanation":""}],
          "review": ["cosas que repasar, en español"]
        }

        En "corrections", "said" es lo que dijo mal el estudiante y "corrected" la forma correcta; incluye solo correcciones que el profesor hizo de verdad.
        En "marks", "at" debe coincidir exactamente con uno de los segundos que te doy en los momentos marcados, y "explanation" cuenta en español qué se estaba explicando ahí y resuelve la duda.
        """
    }

    private static func prompt(meta: ClassMeta,
                               segments: [TranscriptSegment],
                               marks: [ClassMark]) -> String {
        var text = """
        Clase: \(meta.title)
        Idioma: \(meta.language.label)
        Duración: \(ClassRecorder.timecode(meta.duration))

        Transcripción:
        \(ClassQuickAsk.render(segments, maxCharacters: 120_000))
        """

        if !marks.isEmpty {
            let lines = marks.map { mark -> String in
                let label = mark.kind == .notUnderstood ? "no lo entendí" : "importante"
                return "- \(Int(mark.at.rounded())) s (\(ClassRecorder.timecode(mark.at))): \(label)"
            }
            text += """


            Momentos que el estudiante marcó durante la clase (usa estos segundos exactos en "marks"):
            \(lines.joined(separator: "\n"))
            """
        }
        return text
    }

    // MARK: - Parsing

    private static func parse(_ raw: String, classId: String) throws -> ClassNotesDoc {
        // Models sometimes wrap JSON in a code fence despite being told not to.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                       .replacingOccurrences(of: "```", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8) else {
            throw NSError(domain: "ClassNotes", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "La respuesta no contenía JSON."])
        }

        struct Payload: Decodable {
            var summary: String?
            var vocabulary: [VocabularyItem]?
            var grammar: [GrammarPoint]?
            var phrases: [UsefulPhrase]?
            var corrections: [Correction]?
            var marks: [RawMark]?
            var review: [String]?
            struct RawMark: Decodable { var at: TimeInterval; var explanation: String }
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var doc = ClassNotesDoc(classId: classId, generatedAt: .now)
        doc.summary     = payload.summary ?? ""
        doc.vocabulary  = payload.vocabulary ?? []
        doc.grammar     = payload.grammar ?? []
        doc.phrases     = payload.phrases ?? []
        doc.corrections = payload.corrections ?? []
        doc.review      = payload.review ?? []
        doc.marks = (payload.marks ?? []).map {
            MarkNote(at: $0.at, kind: .important, excerpt: "", explanation: $0.explanation)
        }
        return doc
    }

    /// Fills each mark with the real transcript around it, taken from our own
    /// data rather than from the model — quoting is not something to delegate.
    private static func attachExcerpts(_ notes: [MarkNote],
                                       marks: [ClassMark],
                                       segments: [TranscriptSegment]) -> [MarkNote] {
        marks.map { mark in
            let note = notes.min { abs($0.at - mark.at) < abs($1.at - mark.at) }
            let matched = note.map { abs($0.at - mark.at) < 15 } ?? false
            let window = segments.filter { $0.end > mark.at - 25 && $0.start < mark.at + 10 }
            let excerpt = window.map { segment -> String in
                let who = segment.speaker == .clase ? "Clase" : "Yo"
                return "\(who): \(segment.text)"
            }.joined(separator: "\n")

            return MarkNote(at: mark.at,
                            kind: mark.kind,
                            excerpt: excerpt,
                            explanation: matched ? (note?.explanation ?? "") : "")
        }
    }

    // MARK: - Markdown

    static func renderMarkdown(_ doc: ClassNotesDoc, meta: ClassMeta) -> String {
        var out = "# \(meta.title)\n\n"
        out += "\(meta.language.label) · \(ClassRecorder.dateFormatter.string(from: meta.startedAt))"
        out += " · \(ClassRecorder.timecode(meta.duration))\n\n"

        if !doc.summary.isEmpty {
            out += "## Resumen\n\n\(doc.summary)\n\n"
        }
        if !doc.vocabulary.isEmpty {
            out += "## Vocabulario nuevo\n\n"
            for item in doc.vocabulary {
                out += "- **\(item.term)** — \(item.translation)\n"
                if !item.example.isEmpty {
                    out += "  - *\(item.example)*"
                    if let translation = item.exampleTranslation, !translation.isEmpty {
                        out += " → \(translation)"
                    }
                    out += "\n"
                }
            }
            out += "\n"
        }
        if !doc.grammar.isEmpty {
            out += "## Gramática\n\n"
            for point in doc.grammar {
                out += "### \(point.title)\n\n\(point.explanation)\n\n"
                for example in point.examples { out += "- *\(example)*\n" }
                if !point.examples.isEmpty { out += "\n" }
            }
        }
        if !doc.phrases.isEmpty {
            out += "## Frases y expresiones útiles\n\n"
            for phrase in doc.phrases {
                out += "- **\(phrase.phrase)** — \(phrase.meaning)"
                if let context = phrase.context, !context.isEmpty { out += " *(\(context))*" }
                out += "\n"
            }
            out += "\n"
        }
        if !doc.corrections.isEmpty {
            out += "## Correcciones\n\n"
            for correction in doc.corrections {
                out += "- ~~\(correction.said)~~ → **\(correction.corrected)**\n"
                out += "  - \(correction.explanation)\n"
            }
            out += "\n"
        }
        if !doc.marks.isEmpty {
            out += "## Mis momentos marcados\n\n"
            for mark in doc.marks {
                let label = mark.kind == .notUnderstood ? "No lo entendí" : "Importante"
                out += "### \(ClassRecorder.timecode(mark.at)) — \(label)\n\n"
                if !mark.excerpt.isEmpty {
                    out += mark.excerpt.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
                    out += "\n\n"
                }
                if !mark.explanation.isEmpty { out += "\(mark.explanation)\n\n" }
            }
        }
        if !doc.review.isEmpty {
            out += "## Para repasar\n\n"
            for item in doc.review { out += "- \(item)\n" }
            out += "\n"
        }
        return out
    }
}
#endif
