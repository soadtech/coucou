#if !APPSTORE
import Foundation
import WhisperKit

// MARK: - WhisperKitEngine
// The only file that knows WhisperKit exists. An actor because WhisperKit is a
// plain class and decoding must be serialised anyway: two concurrent decodes
// would fight over the Neural Engine and end up slower than one.

actor WhisperKitEngine: TranscriptionEngine {

    private var pipe: WhisperKit?

    func prepare() async throws {
        guard pipe == nil else { return }
        let folder = try await WhisperModelManager.shared.ensureModel()
        let base = await WhisperModelManager.shared.downloadBase
        do {
            // `download: true` even though the model is already on disk: the
            // tokenizer is a separate artifact that WhisperKit fetches on
            // first load, and blocking downloads here leaves it unable to
            // decode anything at all. `downloadBase` keeps it next to the
            // model instead of in a hidden Hugging Face cache.
            let config = WhisperKitConfig(downloadBase: base,
                                          modelFolder: folder.path,
                                          verbose: false,
                                          logLevel: .error,
                                          prewarm: true,
                                          load: true,
                                          download: true)
            pipe = try await WhisperKit(config)
            NSLog("[ClassWhisper] model ready at %@", folder.lastPathComponent)
        } catch {
            NSLog("[ClassWhisper] load failed: %@", error.localizedDescription)
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
    }

    func transcribe(samples: [Float],
                    offset: TimeInterval,
                    speaker: ClassSpeaker) async throws -> [TranscriptSegment] {
        guard let pipe else { throw TranscriptionError.notPrepared }
        guard !samples.isEmpty else { return [] }

        // No fixed language: a single class mixes Spanish, English and French,
        // so every chunk is detected on its own.
        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad)

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

        return results.flatMap { result -> [TranscriptSegment] in
            let language = result.language
            return result.segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Whisper emits bracketed markers such as [BLANK_AUDIO] on silence.
                guard !text.isEmpty, !(text.hasPrefix("[") && text.hasSuffix("]")) else { return nil }
                guard !Self.isHallucination(segment, text: text) else { return nil }
                return TranscriptSegment(start: offset + TimeInterval(segment.start),
                                         end: offset + TimeInterval(segment.end),
                                         speaker: speaker,
                                         text: text,
                                         language: language)
            }
        }
    }

    // MARK: - Hallucination filter
    //
    // Given silence, Whisper does not return nothing — it returns whichever
    // stock phrase is commonest in its training data: "Thank you.",
    // "Obrigado.", "Gracias.", subtitle credits. The microphone track is silent
    // for most of a class, so without this the student's own transcript fills
    // up with things they never said.
    //
    // The model's own confidence decides: `noSpeechProb` is how sure it is the
    // audio was silence, `avgLogprob` how sure it is of the words it chose.
    // The phrase list is only a second line of defence, and only ever drops a
    // segment that consists of nothing but that phrase.

    /// Whisper's own default no-speech threshold.
    private static let noSpeechLimit: Float = 0.6
    /// Below this the decode was mostly guesswork.
    private static let logProbLimit: Float = -1.0

    private static let stockPhrases: Set<String> = [
        "thank you", "thanks", "thank you very much", "thank you for watching",
        "obrigado", "obrigada", "gracias", "muchas gracias", "merci",
        "you", "bye", "bye bye", "okay", "ok",
        "subtítulos realizados por la comunidad de amara.org",
        "sous-titres réalisés par la communauté d'amara.org",
    ]

    private static func isHallucination(_ segment: TranscriptionSegment, text: String) -> Bool {
        if segment.noSpeechProb >= noSpeechLimit { return true }
        if segment.avgLogprob < logProbLimit { return true }

        let normalised = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!¡?¿…-"))
        return stockPhrases.contains(normalised)
    }
}
#endif
