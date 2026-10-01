#if !APPSTORE
import Foundation
import SwiftUI
import AVFoundation
import Combine

// MARK: - ClassRecorder
// Orchestrates one class: tap the meeting app, capture the microphone, and hand
// both to ClassAudioPipeline, which mixes them into audio.m4a and forwards each
// stream to the transcriber (phase 2) tagged with its speaker.
//
// Nothing here talks to the network. The audio never leaves the Mac.

@MainActor
final class ClassRecorder: ObservableObject {
    static let shared = ClassRecorder()

    // MARK: Published state (island + menu bar read this)

    @Published private(set) var isRecording = false
    @Published private(set) var currentClass: ClassMeta?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?
    /// Smoothed input level of the tapped app, 0…1 — drives the recording indicator.
    @Published private(set) var level: Double = 0

    // MARK: Preferences (persisted)

    @Published var language: ClassLanguage = .english {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "classLanguage") }
    }
    /// Bundle identifier of the last app the user chose to listen to.
    @Published var preferredSourceBundleID: String? {
        didSet { UserDefaults.standard.set(preferredSourceBundleID, forKey: "classSourceBundleID") }
    }
    @Published var captureMicrophone: Bool = true {
        didSet { UserDefaults.standard.set(captureMicrophone, forKey: "classCaptureMic") }
    }

    // MARK: Private

    private let appAudio = AppAudioCapture()
    private let mic = MicCapture()
    private let pipeline = ClassAudioPipeline()
    private var writer: ClassAudioWriter?
    private var ticker: Timer?

    /// Live transcription. Owns its own buffers; fed from the audio threads.
    let transcriber = ClassTranscriber()

    private init() {
        let ud = UserDefaults.standard
        if let raw = ud.string(forKey: "classLanguage"), let v = ClassLanguage(rawValue: raw) { language = v }
        if let v = ud.string(forKey: "classSourceBundleID") { preferredSourceBundleID = v }
        if let v = ud.object(forKey: "classCaptureMic") as? Bool { captureMicrophone = v }
    }

    // MARK: - Source picker

    /// Apps that can be captured, likely meeting apps first.
    func availableSources() async -> [AudioAppInfo] {
        let known: Set<String> = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
                                  "com.google.Chrome", "com.apple.Safari", "com.brave.Browser",
                                  "org.mozilla.firefox", "com.hnc.Discord"]
        return await AudioAppLister.availableApps().sorted { a, b in
            let aKnown = known.contains(a.bundleID)
            let bKnown = known.contains(b.bundleID)
            if aKnown != bKnown { return aKnown }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The source matching the last choice, if that app is still running.
    func preferredSource() async -> AudioAppInfo? {
        guard let bundleID = preferredSourceBundleID else { return nil }
        return await availableSources().first { $0.bundleID == bundleID }
    }

    /// Whether Screen Recording has been granted. ScreenCaptureKit needs it
    /// even though Coucou only ever reads the audio track. Does not prompt.
    var hasScreenRecordingPermission: Bool {
        AudioAppLister.hasPermission
    }

    /// Raises the system dialog once. macOS only applies the grant after a
    /// relaunch, so the caller should say so.
    func requestScreenRecordingPermission() {
        AudioAppLister.requestPermission()
    }

    // MARK: - Lifecycle

    func start(title: String, language: ClassLanguage, source: AudioAppInfo?) async {
        guard !isRecording else { return }
        lastError = nil
        self.language = language

        var micOK = false
        if captureMicrophone {
            if !MicCapture.hasInputDevice {
                // A Mac mini with no headset has no input at all.
                lastError = ClassAudioError.microphoneUnavailable.localizedDescription
            } else {
                micOK = await AudioPermissions.requestMicrophone() == .granted
                if !micOK { lastError = ClassAudioError.microphoneDenied.localizedDescription }
            }
        }
        guard source != nil || micOK else {
            lastError = ClassAudioError.noSource.localizedDescription
            return
        }

        let id = UUID().uuidString
        var meta = ClassMeta(id: id,
                             title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                             language: language,
                             startedAt: .now,
                             sourceAppBundleID: source?.bundleID,
                             sourceAppName: source?.name,
                             whisperModel: WhisperModelManager.shared.selectedModel)
        if meta.title.isEmpty {
            meta.title = "Clase de \(language.label) — \(Self.dateFormatter.string(from: meta.startedAt))"
        }

        do {
            try ClassStore.shared.createDirectory(for: id)
            try ClassStore.shared.saveMeta(meta)
            try ClassStore.shared.saveTranscript(TranscriptDoc(classId: id))
            try ClassStore.shared.saveMarks(MarksDoc(classId: id))
        } catch {
            lastError = "No se pudo crear la carpeta de la clase: \(error.localizedDescription)"
            return
        }

        // The tapped app is the clock when there is one; otherwise the microphone.
        let writer: ClassAudioWriter
        do {
            writer = try ClassAudioWriter(url: ClassStore.shared.audioURL(for: id),
                                          micIsClock: source == nil)
        } catch {
            lastError = error.localizedDescription
            try? ClassStore.shared.delete(id)
            return
        }
        self.writer = writer
        pipeline.configure(writer: writer, tapFormat: nil, micFormat: nil, handler: nil)

        // 1. App audio, before the microphone: opening the input first
        //    reroutes the audio device and the capture goes silent.
        if let source {
            do {
                let pipeline = self.pipeline
                appAudio.onFormat = { format in pipeline.setTapFormat(format) }
                appAudio.onBuffer = { buffer in pipeline.ingestClass(buffer) }
                appAudio.onStop = { [weak self] reason in
                    Task { @MainActor in
                        self?.lastError = "La captura de \(source.name) se detuvo: \(reason)"
                        self?.stop()
                    }
                }
                try await appAudio.start(app: source)
                preferredSourceBundleID = source.bundleID
            } catch {
                lastError = error.localizedDescription
                appAudio.onBuffer = nil
                appAudio.onFormat = nil
                appAudio.onStop = nil
                appAudio.stop()
                pipeline.teardown()
                writer.finish()
                self.writer = nil
                try? ClassStore.shared.delete(id)
                return
            }
        }

        // 2. Microphone. It goes *after* the tap: opening the input first
        //    reroutes the device and the tap then delivers pure silence.
        //    A failure here is not fatal, the class is still recorded.
        if micOK {
            do {
                let pipeline = self.pipeline
                // Same as the app audio: the converter is built from the first
                // buffer's own format, not from what the node claims.
                mic.onFormat = { format in pipeline.setMicFormat(format) }
                mic.onBuffer = { buffer in pipeline.ingestMic(buffer) }
                try mic.start()
            } catch {
                lastError = error.localizedDescription
                mic.onBuffer = nil
                mic.onFormat = nil
                mic.stop()
            }
        }

        // Transcription runs alongside; a failure there never stops recording.
        let writerRef = writer
        pipeline.configure(writer: writer, tapFormat: nil, micFormat: nil,
                           handler: { [transcriber] buffer, speaker in
            transcriber.ingest(buffer, speaker: speaker,
                               classElapsed: writerRef.duration)
        })
        transcriber.start(classId: id, elapsed: { [weak self] in self?.elapsed ?? 0 })

        writer.start()
        currentClass = meta
        isRecording = true
        elapsed = 0
        marks = []
        startTicker()
        NotificationCenter.default.post(name: .classRecordingChanged, object: nil)
    }

    /// Stops capture, finalises audio.m4a and returns the completed meta.
    @discardableResult
    func stop() -> ClassMeta? {
        guard isRecording, var meta = currentClass else { return nil }
        // Flush the transcriber's tail, then write the notes. Both run in the
        // background: the recording is torn down immediately so the UI responds
        // at once, and neither step can lose the audio, which is already saved.
        let finished = currentClass
        Task { [transcriber] in
            await transcriber.finish()
            guard var meta = finished,
                  let saved = ClassStore.shared.loadMeta(meta.id) else { return }
            meta = saved
            // Without a key there are no notes, and failing on every single
            // class would just be noise: recording and transcription are the
            // part that works without AI.
            if GeminiService.shared.isConfigured {
                _ = await ClassNotesGenerator.shared.generate(for: meta)
                NotificationCenter.default.post(name: .classNotesReady, object: meta.id)
            }
        }

        appAudio.onBuffer = nil
        appAudio.onFormat = nil
        appAudio.onStop = nil
        mic.onBuffer = nil
        mic.onFormat = nil
        appAudio.stop()
        mic.stop()
        pipeline.teardown()
        ticker?.invalidate(); ticker = nil

        writer?.finish()
        meta.duration = writer?.duration ?? elapsed
        writer = nil

        meta.endedAt = .now
        meta.isComplete = true
        try? ClassStore.shared.saveMeta(meta)

        isRecording = false
        currentClass = nil
        elapsed = 0
        level = 0
        NotificationCenter.default.post(name: .classRecordingChanged, object: nil)
        return meta
    }

    // MARK: - Marks

    /// Marks the current moment of the class. The timestamp is what matters:
    /// the notes generator later pulls the surrounding transcript and explains
    /// whatever was going on there.
    @discardableResult
    func mark(_ kind: ClassMarkKind, note: String? = nil) -> ClassMark? {
        guard isRecording, let id = currentClass?.id else { return nil }
        let mark = ClassMark(at: elapsed, kind: kind, note: note)
        var doc = ClassStore.shared.loadMarks(id) ?? MarksDoc(classId: id)
        doc.marks.append(mark)
        try? ClassStore.shared.saveMarks(doc)
        marks = doc.marks
        SoundEngine.shared.play("tick")
        return mark
    }

    /// Marks made during the class in progress, for the island to show.
    @Published private(set) var marks: [ClassMark] = []

    // MARK: - Ticker

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = self.writer?.duration ?? self.elapsed
                self.level = self.pipeline.level
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: - Formatting

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    nonisolated static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

extension Notification.Name {
    /// Posted when a class starts or stops, so the island can pin itself open.
    static let classRecordingChanged = Notification.Name("notchBuddy.classRecordingChanged")
    /// Posted with the class id once its notes have been written.
    static let classNotesReady = Notification.Name("notchBuddy.classNotesReady")
}
#endif
