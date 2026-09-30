#if !APPSTORE
import Foundation
import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics

// MARK: - AppAudioCapture
// Captures the audio of another application with ScreenCaptureKit. No video is
// requested — the stream exists only for its audio output — and nothing leaves
// the Mac.
//
// This replaced a Core Audio process-tap implementation. The taps reported a
// sample rate that did not match the stream (48 kHz declared while delivering
// 16 kHz), changed rate mid-recording when a Bluetooth headset switched
// profile, and required copying realtime buffers by hand. SCStream delivers
// CMSampleBuffers at a format it actually honours, and filters by application
// rather than by process, which also removes the need to resolve helper
// processes back to their owning app.

struct AudioAppInfo: Identifiable, Sendable, Hashable {
    let pid: pid_t
    let bundleID: String
    let name: String

    var id: pid_t { pid }
}

enum AppAudioError: LocalizedError {
    case unsupportedOS
    case permissionDenied
    case appNotFound
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "La captura de audio de apps necesita macOS 14.2 o posterior."
        case .permissionDenied:
            return "Coucou necesita permiso de Grabación de Pantalla para escuchar el audio de la app. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla (solo se captura el audio, nunca la imagen)."
        case .appNotFound:
            return "La app elegida ya no está disponible."
        case .streamFailed(let reason):
            return "No se pudo iniciar la captura: \(reason)"
        }
    }
}

// MARK: - App listing

enum AudioAppLister {

    /// Applications that can be captured. ScreenCaptureKit lists windowed apps
    /// rather than "apps currently making noise", so this cannot filter by
    /// whether audio is playing right now — which in practice is friendlier:
    /// the meeting app shows up even while nobody is speaking.
    /// Callers must check `hasPermission` first: any call here without the
    /// permission raises the system dialog.
    static func availableApps() async -> [AudioAppInfo] {
        guard #available(macOS 14.2, *) else { return [] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seen = Set<pid_t>()
        var result: [AudioAppInfo] = []
        for app in content.applications {
            guard app.processID != ownPID, !seen.contains(app.processID) else { continue }
            guard !app.applicationName.isEmpty else { continue }
            seen.insert(app.processID)
            result.append(AudioAppInfo(pid: app.processID,
                                       bundleID: app.bundleIdentifier,
                                       name: app.applicationName))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// True once the user has granted Screen Recording.
    ///
    /// Uses the preflight check rather than SCShareableContent: *any* call into
    /// ScreenCaptureKit without the permission raises the system dialog, so
    /// probing with it turns every menu open into another prompt.
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Raises the system dialog once, on purpose. Returns immediately;
    /// macOS requires the app to be relaunched before the grant takes effect.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

// MARK: - Capture

@available(macOS 14.2, *)
final class AppAudioCapture: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {

    /// Called off the main thread with the app's audio.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Called once when the stream's real format is known.
    var onFormat: (@Sendable (AVAudioFormat) -> Void)?
    /// Called if the stream dies on its own (app quit, permission revoked).
    var onStop: (@Sendable (String) -> Void)?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "fr.louisraille.NotchBuddy.classAudio",
                                            qos: .userInitiated)
    private let formatLock = NSLock()
    private var _format: AVAudioFormat?
    private(set) var format: AVAudioFormat? {
        get { formatLock.lock(); defer { formatLock.unlock() }; return _format }
        set { formatLock.lock(); _format = newValue; formatLock.unlock() }
    }

    var isRunning: Bool { stream != nil }

    func start(app: AudioAppInfo) async throws {
        stop()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw AppAudioError.permissionDenied
        }
        guard let target = content.applications.first(where: { $0.processID == app.pid }) else {
            throw AppAudioError.appNotFound
        }

        // Audio only: we still have to name a display for the filter, but the
        // video stream is throttled to the bare minimum and never read.
        guard let display = content.displays.first else {
            throw AppAudioError.streamFailed("no display available")
        }
        let filter = SCContentFilter(display: display,
                                     including: [target],
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(ClassAudio.fileSampleRate)
        config.channelCount = 1
        // Video is mandatory on the stream but we want it to cost nothing.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
        } catch {
            throw AppAudioError.streamFailed(error.localizedDescription)
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        format = nil
        Task { try? await stream.stopCapture() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }

        if format == nil {
            format = buffer.format
            NSLog("[ClassAudio] stream format %.0f Hz, %u ch",
                  buffer.format.sampleRate, buffer.format.channelCount)
            onFormat?(buffer.format)
        }
        onBuffer?(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[ClassAudio] stream stopped: %@", error.localizedDescription)
        self.stream = nil
        onStop?(error.localizedDescription)
    }

    // MARK: Conversion

    /// CMSampleBuffer → AVAudioPCMBuffer. Unlike the process-tap path this does
    /// no manual pointer arithmetic: the framework hands over a described,
    /// correctly sized buffer list.
    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription,
              let asbd = description.audioStreamBasicDescription else { return nil }
        var streamDescription = asbd
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }

        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }
}
#endif
