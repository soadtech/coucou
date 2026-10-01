#if !APPSTORE
import Foundation
import SwiftUI
import AVFoundation

// MARK: - SpeakerBuffer
// Accumulates one speaker's 16 kHz mono audio. Written from realtime audio
// threads, drained from the transcription task, so everything is under a lock.

private final class SpeakerBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Samples already cut into chunks — this is the speaker's clock.
    private var consumed: Int = 0
    /// When this speaker's first sample arrived, relative to the class start.
    private var startOffset: TimeInterval?

    /// Hard ceiling on the backlog: five minutes of audio. If transcription
    /// cannot keep up on a slow machine, dropping the oldest audio is far
    /// better than growing to gigabytes over a one-hour class — and nothing is
    /// truly lost, since audio.m4a still holds everything and the class can be
    /// re-transcribed afterwards.
    private static let maxBacklogSeconds = 300.0

    func append(_ buffer: AVAudioPCMBuffer, classElapsed: TimeInterval) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let incoming = Array(UnsafeBufferPointer(start: channel, count: count))

        lock.lock()
        // The microphone can start later than the app audio; anchor this
        // speaker's timeline the first time we hear from it.
        if startOffset == nil { startOffset = classElapsed }
        samples.append(contentsOf: incoming)

        let cap = Int(Self.maxBacklogSeconds * ClassAudio.transcriptionSampleRate)
        if samples.count > cap {
            let dropped = samples.count - cap
            samples.removeFirst(dropped)
            consumed += dropped        // keep timestamps honest about the gap
            NSLog("[ClassTranscriber] backlog over %.0fs, dropped %.1fs of audio",
                  Self.maxBacklogSeconds, Double(dropped) / ClassAudio.transcriptionSampleRate)
        }
        lock.unlock()
    }

    var available: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// Removes and returns the first `count` samples, with their start time.
    func take(_ count: Int) -> (samples: [Float], offset: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, samples.count >= count else { return nil }
        let chunk = Array(samples[0..<count])
        samples.removeFirst(count)
        let offset = (startOffset ?? 0)
            + Double(consumed) / ClassAudio.transcriptionSampleRate
        consumed += count
        return (chunk, offset)
    }

    /// A read-only view for deciding where to cut.
    func peek() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        consumed = 0
        startOffset = nil
        lock.unlock()
    }
}

// MARK: - ClassTranscriber
// Turns the two live audio streams into transcript.json, one chunk at a time.
// Chunks are cut at silence rather than at a fixed length so words are not
// sliced in half.

@MainActor
final class ClassTranscriber: ObservableObject {

    /// Everything transcribed so far, in class order.
    @Published private(set) var segments: [TranscriptSegment] = []
    /// Set when transcription fails; recording is never interrupted by it.
    @Published private(set) var lastError: String?
    /// True while a chunk is being decoded — drives the island indicator.
    @Published private(set) var isTranscribing = false

    /// The last few lines, for the notch hover view (phase 3).
    var recentSegments: [TranscriptSegment] { Array(segments.suffix(3)) }

    // MARK: Chunking policy

    private let rate = ClassAudio.transcriptionSampleRate
    /// Never send Whisper less than this: short chunks transcribe badly.
    private let minChunkSeconds: Double = 5
    /// Preferred length — long enough for context, short enough to feel live.
    private let targetChunkSeconds: Double = 15
    /// Hard cut even mid-sentence past this.
    private let maxChunkSeconds: Double = 30
    /// A gap this long counts as a sentence boundary.
    private let silenceSeconds: Double = 0.4
    /// Frames below this RMS are treated as silence.
    private let silenceThreshold: Float = 0.006
    /// A chunk with less speech than this is dropped instead of transcribed.
    private let minVoicedSeconds: Double = 0.6

    // MARK: State

    private let engine: TranscriptionEngine
    private let buffers: [ClassSpeaker: SpeakerBuffer] = [.clase: SpeakerBuffer(), .yo: SpeakerBuffer()]
    private var classId: String?
    private var doc: TranscriptDoc?
    private var pump: Task<Void, Never>?
    private var elapsedProvider: (@MainActor () -> TimeInterval)?

    init(engine: TranscriptionEngine = WhisperKitEngine()) {
        self.engine = engine
    }

    // MARK: Lifecycle

    func start(classId: String, elapsed: @escaping @MainActor () -> TimeInterval) {
        stop()
        self.classId = classId
        self.elapsedProvider = elapsed
        self.doc = ClassStore.shared.loadTranscript(classId) ?? TranscriptDoc(classId: classId)
        segments = doc?.segments ?? []
        lastError = nil
        buffers.values.forEach { $0.reset() }

        pump = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.prepare()
            } catch {
                NSLog("[ClassTranscriber] engine unavailable: %@", error.localizedDescription)
                await MainActor.run { self.lastError = error.localizedDescription }
                return
            }
            await self.runPump()
        }
    }

    /// Flushes whatever is left and finishes writing transcript.json.
    func finish() async {
        pump?.cancel()
        pump = nil
        await drain(flush: true)
        save()
        classId = nil
        elapsedProvider = nil
    }

    private func stop() {
        pump?.cancel()
        pump = nil
    }

    // MARK: Audio in (realtime threads)

    nonisolated func ingest(_ buffer: AVAudioPCMBuffer, speaker: ClassSpeaker, classElapsed: TimeInterval) {
        buffers[speaker]?.append(buffer, classElapsed: classElapsed)
    }

    // MARK: Pump

    private func runPump() async {
        while !Task.isCancelled {
            await drain(flush: false)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func drain(flush: Bool) async {
        for speaker in [ClassSpeaker.clase, .yo] {
            guard let buffer = buffers[speaker] else { continue }
            while let count = chunkLength(in: buffer, flush: flush),
                  let taken = buffer.take(count) {
                await transcribe(taken.samples, offset: taken.offset, speaker: speaker)
                if Task.isCancelled && !flush { return }
            }
        }
    }

    /// How many samples to cut now, or nil if we should wait for more audio.
    private func chunkLength(in buffer: SpeakerBuffer, flush: Bool) -> Int? {
        let available = buffer.available
        let minSamples = Int(minChunkSeconds * rate)

        if flush {
            return available > Int(0.5 * rate) ? available : nil
        }
        guard available >= minSamples else { return nil }

        let maxSamples = Int(maxChunkSeconds * rate)
        if available >= maxSamples { return maxSamples }

        let targetSamples = Int(targetChunkSeconds * rate)
        guard available >= targetSamples else {
            // Not at target length yet, but cut early if the speaker has
            // clearly stopped talking — that keeps the live view responsive.
            return trailingSilenceStart(buffer.peek(), after: minSamples)
        }
        // At target length: prefer the last silence, fall back to a hard cut.
        return lastSilence(buffer.peek(), between: minSamples, and: targetSamples) ?? targetSamples
    }

    // MARK: Silence detection
    //
    // Plain energy VAD over 20 ms frames. WhisperKit has its own VAD for
    // splitting inside a chunk; this one only decides where chunks end.

    private func frameIsSilent(_ samples: [Float], at index: Int, frame: Int) -> Bool {
        let end = min(index + frame, samples.count)
        guard index < end else { return true }
        var sum: Float = 0
        for i in index..<end { sum += samples[i] * samples[i] }
        return (sum / Float(end - index)).squareRoot() < silenceThreshold
    }

    /// Index where a long-enough silence starts at the very end of the buffer.
    private func trailingSilenceStart(_ samples: [Float], after minimum: Int) -> Int? {
        let frame = Int(0.02 * rate)
        let needed = Int(silenceSeconds * rate) / frame
        guard samples.count > minimum, needed > 0 else { return nil }

        var silentFrames = 0
        var index = samples.count - frame
        while index >= minimum {
            guard frameIsSilent(samples, at: index, frame: frame) else { break }
            silentFrames += 1
            index -= frame
        }
        guard silentFrames >= needed else { return nil }
        return max(minimum, index + frame)
    }

    /// Latest silence boundary inside a range, scanning backwards.
    private func lastSilence(_ samples: [Float], between lower: Int, and upper: Int) -> Int? {
        let frame = Int(0.02 * rate)
        let needed = Int(silenceSeconds * rate) / frame
        guard needed > 0, upper > lower, samples.count >= upper else { return nil }

        var run = 0
        var index = upper - frame
        while index >= lower {
            if frameIsSilent(samples, at: index, frame: frame) {
                run += 1
                if run >= needed { return index + run * frame }
            } else {
                run = 0
            }
            index -= frame
        }
        return nil
    }

    // MARK: Transcribe one chunk

    /// Seconds of the chunk that actually carry speech.
    private func voicedSeconds(_ samples: [Float]) -> Double {
        let frame = Int(0.02 * rate)
        guard frame > 0, samples.count >= frame else { return 0 }
        var voiced = 0
        var index = 0
        while index + frame <= samples.count {
            if !frameIsSilent(samples, at: index, frame: frame) { voiced += 1 }
            index += frame
        }
        return Double(voiced) * 0.02
    }

    private func transcribe(_ samples: [Float], offset: TimeInterval, speaker: ClassSpeaker) async {
        // Never hand Whisper a chunk that is essentially silence: it does not
        // return an empty result, it invents a plausible sentence. The
        // microphone track is quiet for most of a class, so this matters.
        guard voicedSeconds(samples) >= minVoicedSeconds else { return }

        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let new = try await engine.transcribe(samples: samples, offset: offset, speaker: speaker)
            NSLog("[ClassTranscriber] %@ chunk %.1fs at %.1fs -> %d segments",
                  speaker.rawValue, Double(samples.count) / rate, offset, new.count)
            guard !new.isEmpty else { return }
            segments.append(contentsOf: new)
            segments.sort { $0.start < $1.start }
            doc?.segments = segments
            save()
        } catch {
            // A failed chunk loses that stretch of transcript but must never
            // stop the recording — the audio is still being written.
            NSLog("[ClassTranscriber] chunk failed: %@", error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    // MARK: Persistence

    private func save() {
        guard let doc else { return }
        let snapshot = doc
        let title = ClassStore.shared.loadMeta(snapshot.classId)?.title ?? "Clase"
        Task.detached(priority: .utility) {
            try? ClassStore.shared.saveTranscript(snapshot)
            // Also as plain text, written every time: readable without the app,
            // and whatever was transcribed survives even if the class never
            // gets stopped cleanly.
            let text = Self.plainText(snapshot.segments, title: title)
            try? text.write(to: ClassStore.shared.transcriptTextURL(for: snapshot.classId),
                            atomically: true, encoding: .utf8)
        }
    }

    nonisolated static func plainText(_ segments: [TranscriptSegment], title: String) -> String {
        var out = "# \(title)\n\n"
        for segment in segments {
            let who: String
            switch segment.speaker {
            case .clase: who = "Clase"
            case .yo: who = "Yo"
            case .desconocido: who = "—"
            }
            out += "[\(ClassRecorder.timecode(segment.start))] \(who): \(segment.text)\n"
        }
        return out
    }
}
#endif
