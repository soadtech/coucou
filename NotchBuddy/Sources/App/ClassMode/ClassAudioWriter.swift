#if !APPSTORE
import Foundation
import AVFoundation

// MARK: - Processing format
// Both sources are resampled to this before anything else happens: it is what
// the m4a is written from and what Whisper expects in phase 2.

enum ClassAudio {
    /// What audio.m4a is written at. Higher than Whisper needs, because these
    /// recordings get listened back to for study; 16 kHz mono is fine for
    /// transcription but thin for the ear. Costs ~28 MB per hour.
    static let fileSampleRate: Double = 48_000
    /// What the transcriber is fed.
    static let transcriptionSampleRate: Double = 16_000

    static let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: fileSampleRate,
                                          channels: 1,
                                          interleaved: false)!
    static let transcriptionFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: transcriptionSampleRate,
                                                   channels: 1,
                                                   interleaved: false)!
}

// MARK: - PCMResampler
// One converter per source, reused for every buffer.

final class PCMResampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.outputFormat = output
    }

    func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered { status.pointee = .noDataNow; return nil }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

// MARK: - ClassAudioWriter
// Sums the two sources into a single mono AAC file. The tapped app is the
// clock: every drain takes N frames of class audio and pairs them with up to N
// frames of microphone, padding with silence when the mic is behind and
// dropping the excess when it runs ahead. Good enough for a lecture recording,
// and it keeps the two transcription streams untouched.

final class ClassAudioWriter: @unchecked Sendable {

    private let lock = NSLock()
    private var classSamples: [Float] = []
    private var micSamples: [Float] = []

    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.classWriter", qos: .utility)

    /// Frames written so far — the authoritative class duration.
    private var framesWritten: AVAudioFramePosition = 0

    /// Seconds of audio committed to disk.
    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(framesWritten) / ClassAudio.fileSampleRate
    }

    /// If no app is tapped, the microphone becomes the clock instead.
    private let micIsClock: Bool

    init(url: URL, micIsClock: Bool) throws {
        self.micIsClock = micIsClock
        let settings: [String: Any] = [
            AVFormatIDKey:          kAudioFormatMPEG4AAC,
            AVSampleRateKey:        ClassAudio.fileSampleRate,
            AVNumberOfChannelsKey:  1,
            AVEncoderBitRateKey:    64_000,
        ]
        do {
            file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw ClassAudioError.fileCreationFailed(error.localizedDescription)
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    /// Flushes what is left and closes the file. Safe to call twice.
    func finish() {
        timer?.cancel()
        timer = nil
        queue.sync { self.drain(flush: true) }
        lock.lock()
        file = nil
        lock.unlock()
    }

    // MARK: Ingest (called from realtime threads)

    func appendClass(_ buffer: AVAudioPCMBuffer) { append(buffer, to: \.classSamples) }
    func appendMic(_ buffer: AVAudioPCMBuffer)   { append(buffer, to: \.micSamples) }

    private func append(_ buffer: AVAudioPCMBuffer, to keyPath: ReferenceWritableKeyPath<ClassAudioWriter, [Float]>) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: frames))

        lock.lock()
        self[keyPath: keyPath].append(contentsOf: samples)
        // Safety valve: never let a stalled drain grow the queues without bound (~60 s).
        let cap = Int(ClassAudio.fileSampleRate * 60)
        if self[keyPath: keyPath].count > cap {
            self[keyPath: keyPath].removeFirst(self[keyPath: keyPath].count - cap)
        }
        lock.unlock()
    }

    // MARK: Drain

    private func drain(flush: Bool = false) {
        lock.lock()
        guard let file else { lock.unlock(); return }

        // How many frames to commit this round, decided by the clock source.
        let available = micIsClock ? micSamples.count : classSamples.count
        let count = flush ? max(classSamples.count, micSamples.count) : available
        guard count > 0 else { lock.unlock(); return }

        var mixed = [Float](repeating: 0, count: count)

        let classCount = min(count, classSamples.count)
        for i in 0..<classCount { mixed[i] += classSamples[i] }
        classSamples.removeFirst(classCount)

        let micCount = min(count, micSamples.count)
        for i in 0..<micCount { mixed[i] += micSamples[i] }
        micSamples.removeFirst(micCount)

        // Drop microphone backlog rather than let it drift behind for the whole class.
        if !flush, micSamples.count > count * 2 {
            micSamples.removeFirst(micSamples.count - count)
        }

        // Summing two sources can clip; clamp instead of wrapping.
        for i in 0..<count { mixed[i] = max(-1, min(1, mixed[i])) }

        framesWritten += AVAudioFramePosition(count)
        lock.unlock()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: ClassAudio.fileFormat,
                                            frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        mixed.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: count)
        }
        try? file.write(from: buffer)
    }
}
#endif
