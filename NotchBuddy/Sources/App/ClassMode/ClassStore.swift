#if !APPSTORE
import Foundation

// MARK: - ClassStore
// On-disk layout for Class Mode. Everything stays local:
//   ~/Library/Application Support/Coucou/Classes/<id>/
//     audio.m4a  transcript.json  notes.json  notes.md  marks.json  meta.json
//
// All documents carry `schemaVersion` — the export format is documented in
// docs/class-mode-schema.md and must stay stable.

enum ClassLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case french  = "fr"

    /// Label shown in the island / menu bar (Spanish — the user's language).
    var label: String {
        switch self {
        case .english: return "Inglés"
        case .french:  return "Francés"
        }
    }
}

/// Who is speaking. The two audio sources are captured separately, so this is
/// known exactly — no diarization involved.
enum ClassSpeaker: String, Codable, Sendable {
    case clase        // the meeting app's audio (teacher, other students)
    case yo           // the local microphone
    /// Only produced by re-transcribing a saved recording: audio.m4a is a
    /// mix of both sources, so the two voices can no longer be told apart.
    case desconocido
}

// MARK: - Documents

struct ClassMeta: Codable, Sendable, Identifiable {
    var schemaVersion: Int = 1
    var id: String
    var title: String
    var language: ClassLanguage
    var startedAt: Date
    var endedAt: Date?
    /// Seconds of captured audio.
    var duration: TimeInterval = 0
    /// Bundle identifier of the app that was tapped, if any.
    var sourceAppBundleID: String?
    var sourceAppName: String?
    /// Whisper model used for the transcript (filled in phase 2).
    var whisperModel: String?
    /// true once the audio file has been finalised.
    var isComplete: Bool = false
}

struct TranscriptSegment: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    /// Seconds from the start of the class.
    var start: TimeInterval
    var end: TimeInterval
    var speaker: ClassSpeaker
    var text: String
    /// BCP-47-ish code detected by Whisper ("es", "en", "fr"). nil = unknown.
    var language: String?
}

struct TranscriptDoc: Codable, Sendable {
    var schemaVersion: Int = 1
    var classId: String
    var segments: [TranscriptSegment] = []
}

enum ClassMarkKind: String, Codable, Sendable {
    case notUnderstood   // "no lo entendí"
    case important       // "importante"
}

struct ClassMark: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    /// Seconds from the start of the class.
    var at: TimeInterval
    var kind: ClassMarkKind
    var note: String?
}

struct MarksDoc: Codable, Sendable {
    var schemaVersion: Int = 1
    var classId: String
    var marks: [ClassMark] = []
}

// MARK: - Store

/// Filesystem access for Class Mode. All calls are synchronous and cheap
/// (small JSON files); callers hop off the main thread when writing often.
final class ClassStore: @unchecked Sendable {
    static let shared = ClassStore()

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    // MARK: Paths

    /// ~/Library/Application Support/Coucou/Classes
    var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coucou/Classes", isDirectory: true)
    }

    func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func audioURL(for id: String)      -> URL { directory(for: id).appendingPathComponent("audio.m4a") }
    func metaURL(for id: String)       -> URL { directory(for: id).appendingPathComponent("meta.json") }
    func transcriptURL(for id: String) -> URL { directory(for: id).appendingPathComponent("transcript.json") }
    func notesURL(for id: String)      -> URL { directory(for: id).appendingPathComponent("notes.json") }
    func notesMarkdownURL(for id: String) -> URL { directory(for: id).appendingPathComponent("notes.md") }
    func marksURL(for id: String)      -> URL { directory(for: id).appendingPathComponent("marks.json") }

    @discardableResult
    func createDirectory(for id: String) throws -> URL {
        let dir = directory(for: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Read / write

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    func saveMeta(_ meta: ClassMeta) throws       { try save(meta, to: metaURL(for: meta.id)) }
    func loadMeta(_ id: String) -> ClassMeta?     { load(ClassMeta.self, from: metaURL(for: id)) }
    func saveTranscript(_ doc: TranscriptDoc) throws { try save(doc, to: transcriptURL(for: doc.classId)) }
    func loadTranscript(_ id: String) -> TranscriptDoc? { load(TranscriptDoc.self, from: transcriptURL(for: id)) }
    func saveMarks(_ doc: MarksDoc) throws        { try save(doc, to: marksURL(for: doc.classId)) }
    func loadMarks(_ id: String) -> MarksDoc?     { load(MarksDoc.self, from: marksURL(for: id)) }

    /// All stored classes, newest first. Skips directories without a readable meta.json.
    func allClasses() -> [ClassMeta] {
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .compactMap { loadMeta($0.lastPathComponent) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func delete(_ id: String) throws {
        try fm.removeItem(at: directory(for: id))
    }
}
#endif
