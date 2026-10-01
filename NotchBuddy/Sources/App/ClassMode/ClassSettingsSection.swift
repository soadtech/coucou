#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - ClassSettingsSection
// The "Modo Clase" block inside Settings: which Whisper model to use, its
// download, and whether the microphone is captured alongside the class audio.

struct ClassSettingsSection: View {
    @ObservedObject private var models = WhisperModelManager.shared
    @ObservedObject private var recorder = ClassRecorder.shared
    @State private var showAllModels = false
    @ObservedObject private var state = AppState.shared
    @State private var markFlags: UInt  = AppState.shared.classMarkFlags
    @State private var markCode: UInt16 = AppState.shared.classMarkCode
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var geminiKey: String = KeychainStore.shared.get(GeminiService.keychainKey) ?? ""
    @State private var geminiModel: String = GeminiService.shared.model
    @State private var checkingKey = false
    @State private var keyMessage: String?
    @State private var keyOK = false

    var body: some View {
        GroupBox("Modo Clase") {
            VStack(alignment: .leading, spacing: 10) {

                Toggle("Usar Coucou solo para clases y reuniones", isOn: $state.classOnlyMode)
                Text("Oculta Claude Code, las integraciones, el chat general y el arrastre de archivos. No se borra nada: puedes volver a activarlo cuando quieras. Requiere reiniciar la app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.25)

                // MARK: AI
                Text("Inteligencia artificial").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField("API key de Gemini", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                    Button(checkingKey ? "Comprobando…" : "Guardar") { saveKey() }
                        .disabled(checkingKey || geminiKey.isEmpty)
                }
                if let keyMessage {
                    Text(keyMessage)
                        .font(.caption)
                        .foregroundStyle(keyOK ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Sin key, Coucou graba, transcribe en local, guarda tus marcas y conserva el historial. Los apuntes y el chat sí la necesitan. Solo se envía texto: el audio nunca sale de este Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Modelo").font(.caption)
                    TextField("gemini-2.5-flash", text: $geminiModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { GeminiService.shared.model = geminiModel }
                }

                Divider().opacity(0.25)

                Picker("Whisper model", selection: $models.selectedModel) {
                    ForEach(modelChoices, id: \.self) { model in
                        Text(label(for: model)).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Text("Transcription runs entirely on this Mac. Multilingual models only — a class mixes Spanish, English and French.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                statusRow

                // The transcriber's own failures used to be visible only in the
                // island, where they scroll past. A class that recorded but
                // never transcribed has to say why here too.
                if let error = ClassRecorder.shared.transcriber.lastError {
                    Text("Última transcripción: \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Also record my microphone", isOn: $recorder.captureMicrophone)
                Text("Keeps “Clase” and “Yo” apart in the transcript. With Bluetooth headphones this switches them to call mode and lowers the audio quality.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().opacity(0.25)

                Toggle("Global shortcut to mark a moment", isOn: $state.classMarkHotkeyEnabled)
                if state.classMarkHotkeyEnabled {
                    HStack(spacing: 8) {
                        ShortcutRecorderButton(flags: $markFlags, code: $markCode)
                            .onChange(of: markFlags) { _, v in state.classMarkFlags = v }
                            .onChange(of: markCode)  { _, v in state.classMarkCode  = v }
                        Text("Marks the current moment as “no lo entendí”, from any app. Only active while a class is recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !accessibilityTrusted {
                        // Global shortcuts are delivered through an event
                        // monitor, which macOS silently starves without this
                        // permission — the key simply does nothing.
                        HStack(spacing: 8) {
                            Text("Global shortcuts need Accessibility permission, which Coucou does not have yet.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }

                Toggle("Show every available model", isOn: $showAllModels)
                    .font(.caption)
                    .onChange(of: showAllModels) { _, on in
                        if on { Task { await models.loadAvailableModels() } }
                    }
            }
            .padding(6)
        }
        .onAppear { accessibilityTrusted = AXIsProcessTrusted() }
    }

    /// The key is checked against the API before being kept, so a typo shows
    /// up here instead of halfway through generating notes for a real meeting.
    private func saveKey() {
        let trimmed = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !checkingKey else { return }
        checkingKey = true
        keyMessage = nil
        Task {
            let result = await GeminiService.shared.validate(key: trimmed)
            checkingKey = false
            switch result {
            case .success:
                keyOK = true
                keyMessage = "✓ Key válida y guardada."
            case .failure(let error):
                keyOK = false
                keyMessage = error.localizedDescription
            }
        }
    }

    private var modelChoices: [String] {
        let base = showAllModels && !models.availableModels.isEmpty
            ? models.availableModels
            : WhisperModelManager.suggestedModels
        // Never lose the current selection from the list.
        return base.contains(models.selectedModel) ? base : [models.selectedModel] + base
    }

    private func label(for model: String) -> String {
        models.isDownloaded(model) ? "\(model)  ✓" : model
    }

    @ViewBuilder
    private var statusRow: some View {
        switch models.state {
        case .ready:
            HStack(spacing: 6) {
                Text("Model ready").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Re-download") { models.repairModel() }.font(.caption)
                Button("Delete") { models.deleteModel(models.selectedModel) }.font(.caption)
            }
        case .notDownloaded:
            HStack(spacing: 8) {
                Text("Not downloaded yet").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Download now") { Task { _ = try? await models.ensureModel() } }
                    .font(.caption)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("Downloading… \(Int(progress * 100)) %")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Delete and download again") { models.repairModel() }.font(.caption)
            }
        }
    }
}
#endif
