#if !APPSTORE
import Foundation
import AppKit
import AVFoundation

// MARK: - AudioPermissions
// Microphone access goes through AVCaptureDevice. System-audio capture (process
// taps) has no request API: the prompt appears the first time a tap is created,
// and a refusal surfaces as AudioTapError.permissionDenied.

enum AudioPermissions {

    enum Status { case granted, denied, notDetermined }

    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .notDetermined: return .notDetermined
        default:             return .denied
        }
    }

    /// Prompts on first call; returns immediately afterwards.
    static func requestMicrophone() async -> Status {
        switch microphone {
        case .granted: return .granted
        case .denied:  return .denied
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            return ok ? .granted : .denied
        }
    }

    // MARK: System Settings deep links

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAudioCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
