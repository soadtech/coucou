#if !APPSTORE
import SwiftUI

// MARK: - ClassHomeView
// What the notch shows when it is opened and no class is running. In
// class-only mode this is the island's home: starting a class and getting back
// to a recent one, nothing else.

struct ClassHomeView: View {
    @ObservedObject private var recorder = ClassRecorder.shared
    @ObservedObject private var models = WhisperModelManager.shared
    @State private var recent: [ClassMeta] = []

    var body: some View {
        ZStack {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Clases y reuniones")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Spacer()
                    if !models.isDownloaded(models.selectedModel) {
                        Text("sin modelo de transcripción")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(hex: "#F5A524"))
                    }
                }

                HStack(spacing: 8) {
                    PrimaryButton("Empezar una clase") {
                        NotificationCenter.default.post(name: .islandShowClassStart, object: nil)
                    }
                    SecondaryButton("Mis clases") {
                        ClassWindowController.shared.show()
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                }

                if recent.isEmpty {
                    Text("Todavía no has grabado ninguna. Mochi escucha la reunión, la transcribe en este Mac y te deja los apuntes.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6E737C"))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(recent) { meta in
                            Button {
                                ClassWindowController.shared.show()
                                NotificationCenter.default.post(name: .islandCollapse, object: nil)
                            } label: {
                                HStack(spacing: 7) {
                                    Text(meta.title)
                                        .font(.system(size: 11.5))
                                        .foregroundColor(Color(hex: "#D7D9DE"))
                                        .lineLimit(1)
                                    Text("\(meta.language.label) · \(ClassRecorder.timecode(meta.duration))")
                                        .font(.system(size: 10.5))
                                        .foregroundColor(Color(hex: "#6E737C"))
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.leading, 112)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { recent = Array(ClassStore.shared.allClasses().prefix(3)) }
    }
}

// MARK: - ClassStartView
// Choosing what to listen to, the language and an optional title.

struct ClassStartView: View {
    @ObservedObject private var recorder = ClassRecorder.shared
    @ObservedObject private var models = WhisperModelManager.shared
    @State private var title: String = ""
    @State private var sources: [AudioAppInfo] = []
    @State private var selected: AudioAppInfo?
    @State private var loading = true
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 8) {
                Text("Empezar una clase")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))

                HStack(spacing: 8) {
                    ForEach(ClassLanguage.allCases, id: \.self) { language in
                        ChoiceChip(title: language.label,
                                   selected: recorder.language == language) {
                            recorder.language = language
                        }
                    }
                    Divider().frame(height: 16).overlay(Color.white.opacity(0.12))
                    TextField("Título (opcional)", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .focused($focused)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .frame(maxWidth: 190)
                }

                sourceRow

                HStack(spacing: 8) {
                    PrimaryButton("Empezar") { start() }
                    SecondaryButton("Cancelar") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                    if let error = recorder.lastError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#F4505E"))
                            .lineLimit(2)
                    }
                }

                modelRow
            }
            .padding(.leading, 104)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadSources() }
    }

    // MARK: Which app to listen to

    @ViewBuilder
    private var sourceRow: some View {
        if !recorder.hasScreenRecordingPermission {
            HStack(spacing: 8) {
                Text("Falta el permiso de Grabación de pantalla")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#F5A524"))
                SecondaryButton("Conceder") { recorder.requestScreenRecordingPermission() }
            }
        } else if loading {
            Text("Buscando apps…")
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#8E939C"))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sources) { source in
                        ChoiceChip(title: source.name, selected: selected?.pid == source.pid) {
                            selected = source
                        }
                    }
                    ChoiceChip(title: "Solo mi micrófono", selected: selected == nil) {
                        selected = nil
                    }
                }
            }
            .frame(height: 26)
        }
    }

    // MARK: The model has to exist before anything gets transcribed

    @ViewBuilder
    private var modelRow: some View {
        switch models.state {
        case .ready:
            EmptyView()
        case .notDownloaded:
            HStack(spacing: 8) {
                Text("El modelo de transcripción (~1,5 GB) aún no está descargado. La clase se grabará igualmente y se transcribirá después.")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .fixedSize(horizontal: false, vertical: true)
                SecondaryButton("Descargar") { Task { _ = try? await models.ensureModel() } }
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 140)
                Text("Descargando modelo… \(Int(progress * 100)) %")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "#F4505E"))
                .lineLimit(2)
        }
    }

    private func loadSources() async {
        guard recorder.hasScreenRecordingPermission else { loading = false; return }
        sources = await recorder.availableSources()
        selected = await ClassRecorder.shared.preferredSource() ?? sources.first
        loading = false
    }

    private func start() {
        let chosen = selected
        let name = title
        Task {
            await recorder.start(title: name, language: recorder.language, source: chosen)
            if recorder.isRecording {
                NotificationCenter.default.post(name: .islandShowClass, object: nil)
            }
        }
    }
}

// MARK: - ClassListeningView
// What the notch shows during a class: time, the last few lines transcribed,
// and the two things worth doing mid-class — marking a moment and asking.

struct ClassListeningView: View {
    @ObservedObject private var recorder = ClassRecorder.shared
    @ObservedObject private var transcriber = ClassRecorder.shared.transcriber

    var body: some View {
        ZStack {
            CardBackground(wash: .red)
            VStack(alignment: .leading, spacing: 7) {
                header
                transcriptLines
                HStack(spacing: 8) {
                    SecondaryButton("No lo entendí") { recorder.mark(.notUnderstood) }
                    SecondaryButton("Importante")    { recorder.mark(.important) }
                    SecondaryButton("Preguntar") {
                        NotificationCenter.default.post(name: .islandShowClassAsk, object: nil)
                    }
                    Spacer()
                    PrimaryButton("Parar") {
                        recorder.stop()
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                }
            }
            .padding(.leading, 96)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            RecordingDot()
            Text(recorder.currentClass?.title ?? "Clase")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .lineLimit(1)
            Text(ClassRecorder.timecode(recorder.elapsed))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "#8E939C"))
            if !recorder.marks.isEmpty {
                Text("· \(recorder.marks.count) marcas")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            Spacer()
            if transcriber.isTranscribing {
                Text("transcribiendo…")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
        }
    }

    @ViewBuilder
    private var transcriptLines: some View {
        let recent = transcriber.recentSegments
        VStack(alignment: .leading, spacing: 3) {
            if recent.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#6E737C"))
            } else {
                ForEach(recent) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(segment.speaker == .clase ? "Clase" : "Yo")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(segment.speaker == .clase
                                             ? Color(hex: "#22D3EE") : Color(hex: "#A78BFA"))
                            .frame(width: 34, alignment: .leading)
                        Text(segment.text)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(hex: "#D7D9DE"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(height: 54, alignment: .top)
    }

    private var placeholder: String {
        if let error = transcriber.lastError { return error }
        switch WhisperModelManager.shared.state {
        case .ready:        return "Escuchando… las primeras frases tardan unos segundos."
        case .downloading:  return "Descargando el modelo. El audio se está grabando."
        case .notDownloaded: return "Sin modelo: se graba el audio, se transcribirá después."
        case .failed(let m): return m
        }
    }
}

// MARK: - ClassAskView
// A question mid-class, answered from the transcript so far.

struct ClassAskView: View {
    @ObservedObject private var recorder = ClassRecorder.shared
    @ObservedObject private var ask = ClassQuickAsk.shared
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    RecordingDot()
                    Text("Pregunta sobre la clase")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Text(ClassRecorder.timecode(recorder.elapsed))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color(hex: "#8E939C"))
                    Spacer()
                    SecondaryButton("Volver") {
                        NotificationCenter.default.post(name: .islandShowClass, object: nil)
                    }
                }

                answerArea

                HStack(spacing: 8) {
                    TextField("¿Qué ha dicho sobre…?", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(text.isEmpty || ask.isAsking)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.leading, 92)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var answerArea: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                if let question = ask.question {
                    Text(question)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                if ask.isAsking {
                    TypingDotsView()
                } else if let error = ask.error {
                    Text(error).font(.system(size: 11.5)).foregroundColor(Color(hex: "#F4505E"))
                } else if let answer = ask.answer {
                    Text(answer).font(.system(size: 12)).foregroundColor(Color(hex: "#E8E9EC"))
                } else {
                    Text("Se responde con lo transcrito de la clase hasta ahora. Solo se envía texto; el audio no sale del Mac.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6E737C"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 62)
    }

    private func send() {
        let question = text
        text = ""
        Task {
            await ClassQuickAsk.shared.ask(question,
                                           segments: recorder.transcriber.segments,
                                           language: recorder.language)
            focused = true
        }
    }
}

// MARK: - Small pieces

/// The recording indicator. Always visible while capturing — the user must
/// never be unsure whether Coucou is listening.
struct RecordingDot: View {
    @State private var on = true

    var body: some View {
        Circle()
            .fill(Color(hex: "#F4505E"))
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.25)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = false }
    }
}

struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.07))
                .foregroundColor(Color(hex: selected ? "#F5F6F8" : "#B9BDC5"))
                .clipShape(Capsule())
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}
#endif
