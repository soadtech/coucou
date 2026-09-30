#if !APPSTORE
import Foundation
import AVFoundation

// MARK: - ClassAudioPipeline
// The part of the recorder that lives on Core Audio's realtime threads:
// resample → mix into the m4a → forward to the transcriber. Kept apart from
// ClassRecorder because none of this can touch the main actor.

final class ClassAudioPipeline: @unchecked Sendable {

    private let lock = NSLock()
    private var writer: ClassAudioWriter?
    private var tapResampler: PCMResampler?
    private var micResampler: PCMResampler?
    /// Second stage: file format → the lower rate the transcriber wants.
    private var classTranscribe: PCMResampler?
    private var micTranscribe: PCMResampler?
    private var handler: (@Sendable (AVAudioPCMBuffer, ClassSpeaker) -> Void)?
    private var smoothedLevel: Double = 0

    // MARK: Configuration (main thread, before capture starts)

    func configure(writer: ClassAudioWriter?,
                   tapFormat: AVAudioFormat?,
                   micFormat: AVAudioFormat?,
                   handler: (@Sendable (AVAudioPCMBuffer, ClassSpeaker) -> Void)?) {
        lock.lock()
        self.writer = writer
        if let tapFormat { self.tapResampler = PCMResampler(from: tapFormat, to: ClassAudio.fileFormat) }
        if let micFormat { self.micResampler = PCMResampler(from: micFormat, to: ClassAudio.fileFormat) }
        self.classTranscribe = PCMResampler(from: ClassAudio.fileFormat, to: ClassAudio.transcriptionFormat)
        self.micTranscribe = PCMResampler(from: ClassAudio.fileFormat, to: ClassAudio.transcriptionFormat)
        self.handler = handler
        self.smoothedLevel = 0
        lock.unlock()
    }

    func setTapFormat(_ format: AVAudioFormat) {
        lock.lock(); tapResampler = PCMResampler(from: format, to: ClassAudio.fileFormat); lock.unlock()
    }

    func setMicFormat(_ format: AVAudioFormat) {
        lock.lock(); micResampler = PCMResampler(from: format, to: ClassAudio.fileFormat); lock.unlock()
    }

    func teardown() {
        lock.lock()
        writer = nil
        tapResampler = nil
        micResampler = nil
        classTranscribe = nil
        micTranscribe = nil
        handler = nil
        smoothedLevel = 0
        lock.unlock()
    }

    /// Smoothed RMS of the class audio, 0…1. Read from the main thread.
    var level: Double {
        lock.lock(); defer { lock.unlock() }
        return smoothedLevel
    }

    // MARK: Realtime entry points

    func ingestClass(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let resampler = tapResampler
        let writer = self.writer
        let transcribe = self.classTranscribe
        let handler = self.handler
        lock.unlock()

        guard let converted = resampler?.resample(buffer) else { return }
        writer?.appendClass(converted)
        updateLevel(converted)
        forward(converted, speaker: .clase, resampler: transcribe, handler: handler)
    }

    func ingestMic(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let resampler = micResampler
        let writer = self.writer
        let transcribe = self.micTranscribe
        let handler = self.handler
        lock.unlock()

        guard let converted = resampler?.resample(buffer) else { return }
        writer?.appendMic(converted)
        forward(converted, speaker: .yo, resampler: transcribe, handler: handler)
    }

    /// Whisper wants 16 kHz; the file is kept at 48 kHz, so the transcriber
    /// gets its own downsampled copy rather than the stream we archive.
    private func forward(_ buffer: AVAudioPCMBuffer,
                         speaker: ClassSpeaker,
                         resampler: PCMResampler?,
                         handler: (@Sendable (AVAudioPCMBuffer, ClassSpeaker) -> Void)?) {
        guard let handler, let downsampled = resampler?.resample(buffer) else { return }
        handler(downsampled, speaker)
    }

    // MARK: Level

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in 0..<frames { sum += channel[i] * channel[i] }
        let rms = Double((sum / Float(frames)).squareRoot())

        lock.lock()
        // Feeds an animation, not a meter — heavy smoothing is fine.
        smoothedLevel = smoothedLevel * 0.7 + min(1, rms * 8) * 0.3
        lock.unlock()
    }
}
#endif
