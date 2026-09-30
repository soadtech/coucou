#if !APPSTORE
import Foundation
import SwiftUI
import WhisperKit

// MARK: - WhisperModelManager
// Owns which Whisper model is selected and gets it onto disk, with visible
// progress the first time. Models live alongside the classes, never in the
// app bundle.

@MainActor
final class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)   // 0…1
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded
    /// Populated from the model repo the first time Settings asks.
    @Published private(set) var availableModels: [String] = []

    @Published var selectedModel: String = WhisperModelManager.defaultModel {
        didSet {
            guard oldValue != selectedModel else { return }
            UserDefaults.standard.set(selectedModel, forKey: "classWhisperModel")
            // A different model means a different download.
            state = isDownloaded(selectedModel) ? .ready : .notDownloaded
            cachedFolder = nil
        }
    }

    /// Multilingual by design: classes mix Spanish, English and French in the
    /// same session, so an English-only variant is never an option.
    static let defaultModel = "large-v3-v20240930_turbo"

    /// A short curated list; Settings can still show everything the repo has.
    static let suggestedModels = [
        "large-v3-v20240930_turbo",   // best quality, ~1.5 GB
        "large-v3-v20240930_626MB",   // good quality, half the size
        "small",                       // fast, noticeably weaker on French
        "base",                        // fallback for slow machines
    ]

    private var cachedFolder: URL?
    private var downloadToken: UInt64 = 0

    private init() {
        if let stored = UserDefaults.standard.string(forKey: "classWhisperModel") {
            selectedModel = stored
        }
        if isDownloaded(selectedModel) { state = .ready }
    }

    // MARK: Paths

    /// ~/Library/Application Support/Coucou/WhisperModels
    var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coucou/WhisperModels", isDirectory: true)
    }

    private var repoFolder: URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// Where a downloaded model actually lives.
    ///
    /// WhisperKit resolves the directory name from the model repo at download
    /// time and prefixes it — "large-v3-v20240930_turbo" is stored as
    /// "openai_whisper-large-v3-v20240930_turbo" — so the name is matched by
    /// suffix rather than assumed.
    private func folder(for model: String) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: repoFolder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return nil }
        return entries.first { $0.lastPathComponent.hasSuffix(model) }
    }

    /// Every compiled model WhisperKit needs. Checking for "some .mlmodelc" is
    /// not enough: an interrupted download leaves a directory with a couple of
    /// them, which then reports as ready and fails at load time instead.
    private static let requiredModels = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    func isDownloaded(_ model: String) -> Bool {
        guard let url = folder(for: model) else { return false }
        let fm = FileManager.default
        for required in Self.requiredModels {
            let path = url.appendingPathComponent(required)
            // A .mlmodelc is a directory; an empty one means a broken download.
            guard let contents = try? fm.contentsOfDirectory(atPath: path.path),
                  !contents.isEmpty else { return false }
        }
        return true
    }

    /// Deletes a model so the next attempt starts clean. Used when a download
    /// turns out to be incomplete or unusable.
    func repairModel() {
        deleteModel(selectedModel)
        cachedFolder = nil
        state = .notDownloaded
    }

    /// Called by the engine when loading fails despite the files being present.
    func reportLoadFailure(_ message: String) {
        cachedFolder = nil
        state = .failed(message)
    }

    // MARK: Download

    /// Ensures the selected model is on disk and returns its folder.
    /// Safe to call repeatedly: an existing download is reused, never repeated.
    func ensureModel() async throws -> URL {
        if let cachedFolder { return cachedFolder }

        let model = selectedModel
        if isDownloaded(model), let url = folder(for: model) {
            cachedFolder = url
            state = .ready
            return url
        }

        // Progress callbacks hop to the main actor asynchronously, so a late
        // one can land after the download has returned and knock the state back
        // to "downloading". Stamp each attempt and ignore stale reports.
        downloadToken &+= 1
        let token = downloadToken
        state = .downloading(0)

        do {
            let url = try await WhisperKit.download(
                variant: model,
                downloadBase: downloadBase,
                progressCallback: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadToken == token,
                              case .downloading = self.state else { return }
                        self.state = .downloading(progress.fractionCompleted)
                    }
                })
            downloadToken &+= 1        // invalidate any callback still in flight
            cachedFolder = url
            state = .ready
            return url
        } catch {
            downloadToken &+= 1
            state = .failed(error.localizedDescription)
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
    }

    /// Full model list from the repo, for the Settings picker.
    func loadAvailableModels() async {
        guard availableModels.isEmpty else { return }
        let models = (try? await WhisperKit.fetchAvailableModels()) ?? []
        // Hide the English-only variants: they cannot do French.
        availableModels = models.filter { !$0.contains(".en") }
    }

    /// Frees the disk used by a model the user no longer wants.
    func deleteModel(_ model: String) {
        if let url = folder(for: model) { try? FileManager.default.removeItem(at: url) }
        if model == selectedModel {
            state = .notDownloaded
            cachedFolder = nil
        }
    }
}
#endif
