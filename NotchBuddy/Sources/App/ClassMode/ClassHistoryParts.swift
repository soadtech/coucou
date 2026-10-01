#if !APPSTORE
import SwiftUI
import AVFoundation

// MARK: - ClassAudioPlayer
// Plays the saved recording and can jump to a timestamp, so a line of
// transcript or a marked moment is one click away from being heard again.

@MainActor
final class ClassAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var unavailable = false

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var loadedURL: URL?

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            unavailable = true
            return
        }
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        unavailable = false
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate(); ticker = nil
    }

    /// Called when the detail view goes away. Not a deinit: Timer is not
    /// Sendable, so a nonisolated deinit cannot touch it under Swift 6.
    func stop() {
        pause()
        player = nil
        loadedURL = nil
        position = 0
        duration = 0
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        position = player.currentTime
        if !player.isPlaying { play() }
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying && self.isPlaying { self.pause() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

}

// MARK: - ClassPlayerBar

struct ClassPlayerBar: View {
    @ObservedObject var player: ClassAudioPlayer
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .disabled(player.unavailable)

            Slider(value: Binding(
                get: { player.position },
                set: { player.seek(to: $0) }
            ), in: 0...max(player.duration, 1))

            Text("\(ClassRecorder.timecode(player.position)) / \(ClassRecorder.timecode(player.duration))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .onAppear { player.load(url) }
        .opacity(player.unavailable ? 0.4 : 1)
    }
}

// MARK: - ClassNotesBody

struct ClassNotesBody: View {
    let notes: ClassNotesDoc
    @ObservedObject var player: ClassAudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !notes.summary.isEmpty {
                section("Resumen") {
                    Text(notes.summary).font(.system(size: 13)).textSelection(.enabled)
                }
            }
            if !notes.vocabulary.isEmpty {
                section("Vocabulario nuevo") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notes.vocabulary) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(item.term).font(.system(size: 13, weight: .semibold))
                                    Text("—").foregroundStyle(.tertiary)
                                    Text(item.translation).font(.system(size: 13))
                                }
                                if !item.example.isEmpty {
                                    Text(item.example).font(.system(size: 12)).italic()
                                        .foregroundStyle(.secondary)
                                    if let translation = item.exampleTranslation, !translation.isEmpty {
                                        Text(translation).font(.system(size: 12)).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            if !notes.grammar.isEmpty {
                section("Gramática") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(notes.grammar) { point in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.title).font(.system(size: 13, weight: .semibold))
                                Text(point.explanation).font(.system(size: 13))
                                ForEach(point.examples, id: \.self) { example in
                                    Text("· \(example)").font(.system(size: 12)).italic()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            if !notes.phrases.isEmpty {
                section("Frases útiles") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notes.phrases) { phrase in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(phrase.phrase).font(.system(size: 13, weight: .medium))
                                Text(phrase.meaning).font(.system(size: 12)).foregroundStyle(.secondary)
                                if let context = phrase.context, !context.isEmpty {
                                    Text(context).font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            if !notes.corrections.isEmpty {
                section("Correcciones") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notes.corrections) { correction in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(correction.said).strikethrough().foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                    Text(correction.corrected).fontWeight(.semibold)
                                }
                                .font(.system(size: 13))
                                Text(correction.explanation).font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            if !notes.marks.isEmpty {
                section("Mis momentos marcados") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(notes.marks) { mark in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Button(ClassRecorder.timecode(mark.at)) { player.seek(to: mark.at) }
                                        .font(.system(size: 11, design: .monospaced))
                                    Text(mark.kind == .notUnderstood ? "No lo entendí" : "Importante")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                if !mark.excerpt.isEmpty {
                                    Text(mark.excerpt)
                                        .font(.system(size: 12))
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.secondary.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .textSelection(.enabled)
                                }
                                if !mark.explanation.isEmpty {
                                    Text(mark.explanation).font(.system(size: 13)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            if !notes.review.isEmpty {
                section("Para repasar") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes.review, id: \.self) { item in
                            Text("· \(item)").font(.system(size: 13)).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - ClassChatView

struct ClassChatView: View {
    let meta: ClassMeta
    @StateObject private var chat: ClassChat
    @State private var text = ""
    @FocusState private var focused: Bool

    init(meta: ClassMeta) {
        self.meta = meta
        _chat = StateObject(wrappedValue: ClassChat(meta: meta))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty {
                            Text("Pregunta lo que quieras sobre esta clase. Se usa su transcripción completa y sus apuntes como contexto; solo se envía texto.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(chat.messages) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.role == .user ? "Tú" : "Mochi")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(message.text).font(.system(size: 13)).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(message.id)
                        }
                        if chat.isAnswering {
                            ProgressView().controlSize(.small)
                        }
                        if let error = chat.error {
                            Text(error).font(.system(size: 12)).foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("¿Qué quieres saber de esta clase?", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                Button("Enviar", action: send)
                    .disabled(text.isEmpty || chat.isAnswering)
            }
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let question = text
        text = ""
        Task { await chat.ask(question) }
    }
}
#endif
