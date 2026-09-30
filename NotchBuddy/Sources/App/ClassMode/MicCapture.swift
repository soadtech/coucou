#if !APPSTORE
import Foundation
import AVFoundation
import CoreAudio

// MARK: - MicCapture
// The local microphone, captured separately from the meeting app's audio so the
// transcript can tell "Yo" from "Clase" without any diarization.

final class MicCapture: @unchecked Sendable {

    /// Called on an AVAudioEngine tap thread.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Called once with the format of the first buffer actually delivered.
    /// The tap is installed with `format: nil`, so the engine picks the format;
    /// asking the node afterwards can disagree with what arrives, and building
    /// the converter from a mismatched description yields silence.
    var onFormat: (@Sendable (AVAudioFormat) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false

    var isRunning: Bool { engine.isRunning }

    private let formatLock = NSLock()
    private var _format: AVAudioFormat?
    private(set) var format: AVAudioFormat? {
        get { formatLock.lock(); defer { formatLock.unlock() }; return _format }
        set { formatLock.lock(); _format = newValue; formatLock.unlock() }
    }

    /// True when the system actually has an input device. A Mac mini with no
    /// headset connected has none, and AVAudioEngine does not fail gracefully
    /// there: inputNode reports a fictitious 44.1 kHz stereo format, and
    /// installTap then raises an Objective-C exception that Swift cannot catch,
    /// aborting the process.
    static var hasInputDevice: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown && deviceID != 0
    }

    func start() throws {
        guard !engine.isRunning else { return }
        guard Self.hasInputDevice else { throw ClassAudioError.microphoneUnavailable }

        let input = engine.inputNode
        // The *input* format is the hardware's; outputFormat(forBus:) lies when
        // no device is present.
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw ClassAudioError.microphoneUnavailable
        }

        // Pass nil so the engine uses the node's own format. Supplying one that
        // disagrees with the hardware is what raises the uncatchable exception.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if self.format == nil {
                self.format = buffer.format
                self.onFormat?(buffer.format)
            }
            self.onBuffer?(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func stop() {
        format = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    deinit { stop() }
}

enum ClassAudioError: LocalizedError {
    case microphoneUnavailable
    case microphoneDenied
    case fileCreationFailed(String)
    case noSource

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "No hay ningún micrófono conectado. La clase se grabará solo con el audio de la app."
        case .microphoneDenied:
            return "Coucou no tiene permiso para usar el micrófono. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
        case .fileCreationFailed(let reason):
            return "No se pudo crear el archivo de audio: \(reason)"
        case .noSource:
            return "Elige una app que escuchar o activa el micrófono antes de empezar la clase."
        }
    }
}
#endif
