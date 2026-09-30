#if !APPSTORE
import Foundation

// MARK: - TranscriptionEngine
// The boundary that keeps WhisperKit — the project's only third-party
// dependency — out of the rest of the code. Everything above this protocol
// deals in TranscriptSegment.

protocol TranscriptionEngine: Sendable {
    /// Loads the model. May download it the first time; report progress through
    /// WhisperModelManager rather than here.
    func prepare() async throws

    /// Transcribes one chunk of 16 kHz mono audio.
    /// - Parameters:
    ///   - samples: the chunk, at `ClassAudio.transcriptionSampleRate`.
    ///   - offset: seconds from the start of the class, added to every segment.
    ///   - speaker: which stream this chunk came from.
    /// - Returns: segments in class time, tagged with the detected language.
    func transcribe(samples: [Float],
                    offset: TimeInterval,
                    speaker: ClassSpeaker) async throws -> [TranscriptSegment]
}

enum TranscriptionError: LocalizedError {
    case modelUnavailable(String)
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "No se pudo cargar el modelo de transcripción: \(reason)"
        case .notPrepared:
            return "El modelo de transcripción todavía no está listo."
        }
    }
}
#endif
