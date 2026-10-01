#if !APPSTORE
import Foundation
import AppKit

// MARK: - ClassExporter
// Writes one self-contained folder (or zip) per class, holding a single JSON
// built for re-import elsewhere.
//
// The export format is deliberately NOT the on-disk format. On disk the data is
// split across files that suit the app's own writing patterns; the export is
// one flat, documented, versioned document, so a consumer never has to know how
// Coucou happens to store things. The schema is documented in
// docs/class-mode-schema.md and must stay backward compatible.

enum ClassExporter {

    static let exportFormatVersion = 1

    // MARK: Export document

    private struct ExportDocument: Encodable {
        let formatVersion: Int
        let exportedAt: Date
        let generator: String

        let id: String
        let title: String
        /// "en" or "fr".
        let language: String
        let startedAt: Date
        let endedAt: Date?
        /// Seconds.
        let duration: TimeInterval
        let sourceApp: String?
        let transcriptionModel: String?
        /// File name of the recording inside this export, if included.
        let audioFile: String?

        let transcript: [Segment]
        let marks: [Mark]
        let notes: Notes?

        struct Segment: Encodable {
            let start: TimeInterval
            let end: TimeInterval
            /// "clase" (teacher), "yo" (student), "desconocido" (rebuilt from
            /// the mixed recording, speaker unknown).
            let speaker: String
            let text: String
            /// Detected language code, when known.
            let language: String?
        }

        struct Mark: Encodable {
            let at: TimeInterval
            /// "notUnderstood" or "important".
            let kind: String
            let note: String?
            /// Transcript around the mark, when the notes were generated.
            let excerpt: String?
            /// Explanation in Spanish, when the notes were generated.
            let explanation: String?
        }

        struct Notes: Encodable {
            let generatedAt: Date
            let summary: String
            let vocabulary: [Vocabulary]
            let grammar: [Grammar]
            let phrases: [Phrase]
            let corrections: [Correction]
            let review: [String]

            struct Vocabulary: Encodable {
                let term: String
                let translation: String
                let example: String
                let exampleTranslation: String?
            }
            struct Grammar: Encodable {
                let title: String
                let explanation: String
                let examples: [String]
            }
            struct Phrase: Encodable {
                let phrase: String
                let meaning: String
                let context: String?
            }
            struct Correction: Encodable {
                let said: String
                let corrected: String
                let explanation: String
                let at: TimeInterval?
            }
        }
    }

    // MARK: Build

    static func buildDocument(for meta: ClassMeta, includeAudio: Bool) -> Data? {
        let store = ClassStore.shared
        let segments = store.loadTranscript(meta.id)?.segments ?? []
        let marks = store.loadMarks(meta.id)?.marks ?? []
        let notes = store.load(ClassNotesDoc.self, from: store.notesURL(for: meta.id))

        // Marks carry their explanation from the notes, so a consumer gets one
        // complete object instead of having to join two lists by timestamp.
        let markNotes = notes?.marks ?? []
        let exportMarks = marks.map { mark -> ExportDocument.Mark in
            let matched = markNotes.min { abs($0.at - mark.at) < abs($1.at - mark.at) }
            let close = matched.map { abs($0.at - mark.at) < 1 } ?? false
            return ExportDocument.Mark(
                at: mark.at,
                kind: mark.kind.rawValue,
                note: mark.note,
                excerpt: close ? matched?.excerpt : nil,
                explanation: close ? matched?.explanation : nil)
        }

        let document = ExportDocument(
            formatVersion: exportFormatVersion,
            exportedAt: .now,
            generator: "Coucou Class Mode",
            id: meta.id,
            title: meta.title,
            language: meta.language.rawValue,
            startedAt: meta.startedAt,
            endedAt: meta.endedAt,
            duration: meta.duration,
            sourceApp: meta.sourceAppName,
            transcriptionModel: meta.whisperModel,
            audioFile: includeAudio ? "audio.m4a" : nil,
            transcript: segments.map {
                .init(start: $0.start, end: $0.end,
                      speaker: $0.speaker.rawValue, text: $0.text, language: $0.language)
            },
            marks: exportMarks,
            notes: notes.map { notes in
                .init(generatedAt: notes.generatedAt,
                      summary: notes.summary,
                      vocabulary: notes.vocabulary.map {
                          .init(term: $0.term, translation: $0.translation,
                                example: $0.example, exampleTranslation: $0.exampleTranslation)
                      },
                      grammar: notes.grammar.map {
                          .init(title: $0.title, explanation: $0.explanation, examples: $0.examples)
                      },
                      phrases: notes.phrases.map {
                          .init(phrase: $0.phrase, meaning: $0.meaning, context: $0.context)
                      },
                      corrections: notes.corrections.map {
                          .init(said: $0.said, corrected: $0.corrected,
                                explanation: $0.explanation, at: $0.at)
                      },
                      review: notes.review)
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(document)
    }

    // MARK: Write

    enum ExportError: LocalizedError {
        case encodingFailed
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:    return "No se pudo preparar el JSON de la clase."
            case .zipFailed(let r):  return "No se pudo crear el zip: \(r)"
            }
        }
    }

    /// Writes `<destination>/<folder name>/` with class.json, notes.md and the
    /// recording. Returns the folder.
    @discardableResult
    static func exportFolder(_ meta: ClassMeta, to destination: URL,
                             includeAudio: Bool = true) throws -> URL {
        guard let data = buildDocument(for: meta, includeAudio: includeAudio) else {
            throw ExportError.encodingFailed
        }
        let fm = FileManager.default
        let folder = destination.appendingPathComponent(folderName(for: meta), isDirectory: true)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        try data.write(to: folder.appendingPathComponent("class.json"), options: .atomic)

        let markdown = ClassStore.shared.notesMarkdownURL(for: meta.id)
        if fm.fileExists(atPath: markdown.path) {
            try? fm.copyItem(at: markdown, to: folder.appendingPathComponent("notes.md"))
        }
        if includeAudio {
            let audio = ClassStore.shared.audioURL(for: meta.id)
            if fm.fileExists(atPath: audio.path) {
                try? fm.copyItem(at: audio, to: folder.appendingPathComponent("audio.m4a"))
            }
        }
        return folder
    }

    /// Same contents, zipped. Uses NSFileCoordinator's `forUploading` rather
    /// than shelling out, so there is no dependency and no temp-file dance.
    @discardableResult
    static func exportZip(_ meta: ClassMeta, to destination: URL,
                          includeAudio: Bool = true) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("CoucouExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let folder = try exportFolder(meta, to: staging, includeAudio: includeAudio)
        let target = destination.appendingPathComponent(folderName(for: meta) + ".zip")
        try? fm.removeItem(at: target)

        var coordinatorError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder,
                                       options: [.forUploading],
                                       error: &coordinatorError) { zipped in
            do { try fm.copyItem(at: zipped, to: target) } catch { thrown = error }
        }
        if let coordinatorError { throw ExportError.zipFailed(coordinatorError.localizedDescription) }
        if let thrown { throw ExportError.zipFailed(thrown.localizedDescription) }
        return target
    }

    /// "2026-10-01 Clase de frances" — readable, sortable, filesystem-safe.
    static func folderName(for meta: ClassMeta) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: meta.startedAt)

        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let title = meta.title
            .components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = title.count > 60 ? String(title.prefix(60)) : title
        return trimmed.isEmpty ? "\(date) clase" : "\(date) \(trimmed)"
    }
}
#endif
