#if !APPSTORE
import Foundation

// MARK: - ClassNotes
// The study notes generated from a finished class. Written to notes.json and
// notes.md; the JSON schema is documented in docs/class-mode-schema.md and is
// meant to stay stable — it gets imported elsewhere.
//
// Everything a student reads is in Spanish at an A2 level; the foreign-language
// material (words, examples, corrections) stays in its own language.

struct VocabularyItem: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    /// The word or expression, in the language of the class.
    var term: String
    /// Its meaning in Spanish.
    var translation: String
    /// A sentence using it, in the language of the class.
    var example: String
    /// The example rendered in Spanish.
    var exampleTranslation: String?
}

struct GrammarPoint: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    /// Name of the rule, e.g. "Passé composé con avoir".
    var title: String
    /// The explanation, in Spanish, for an A2 learner.
    var explanation: String
    var examples: [String] = []
}

struct UsefulPhrase: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var phrase: String
    var meaning: String
    /// When to use it.
    var context: String?
}

struct Correction: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    /// What the student actually said.
    var said: String
    /// The corrected form.
    var corrected: String
    /// Why, in Spanish.
    var explanation: String
    /// Seconds into the class, when it can be located in the recording.
    var at: TimeInterval?
}

/// A moment the student marked during the class, explained after the fact.
struct MarkNote: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var at: TimeInterval
    var kind: ClassMarkKind
    /// The transcript around the mark.
    var excerpt: String
    /// What was going on there, in Spanish.
    var explanation: String
}

struct ClassNotesDoc: Codable, Sendable {
    var schemaVersion: Int = 1
    var classId: String
    var generatedAt: Date
    /// Model that produced them, for reproducibility.
    var model: String?

    var summary: String = ""
    var vocabulary: [VocabularyItem] = []
    var grammar: [GrammarPoint] = []
    var phrases: [UsefulPhrase] = []
    var corrections: [Correction] = []
    var marks: [MarkNote] = []
    /// Open questions and things to review, in Spanish.
    var review: [String] = []
}
#endif
