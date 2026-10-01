#if !APPSTORE
import Foundation
import SwiftUI

// MARK: - ClassRetranscriber
// Rebuilds transcript.json from a saved recording.
//
// Needed because the live transcript can be lost for reasons the audio is not:
// the model was not downloaded yet, it failed to load, a chunk errored. The
// audio is always on disk, so nothing is ever truly lost — this is how it gets
// recovered.
//
// Caveat worth knowing: audio.m4a mixes both sources, so a rebuilt transcript
// cannot tell teacher from student. Those segments come back as `.desconocido`.

@MainActor
final class ClassRetranscriber: ObservableObject {
    static let shared = ClassRetranscriber()

    enum State: Equatable {
        case idle
        case running(classId: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let engine: TranscriptionEngine = WhisperKitEngine()

    private init() {}

    func isRunning(_ classId: String) -> Bool {
        if case .running(let id) = state { return id == classId }
        return false
    }

    var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    @discardableResult
    func retranscribe(_ meta: ClassMeta) async -> TranscriptDoc? {
        guard !isBusy else { return nil }
        let audio = ClassStore.shared.audioURL(for: meta.id)
        guard FileManager.default.fileExists(atPath: audio.path) else {
            state = .failed("Esta clase no tiene audio guardado.")
            return nil
        }

        state = .running(classId: meta.id)
        do {
            try await engine.prepare()
            let segments = try await engine.transcribeFile(at: audio)
            var doc = TranscriptDoc(classId: meta.id)
            doc.segments = segments
            try ClassStore.shared.saveTranscript(doc)
            state = .idle
            return doc
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }
}
#endif
