#if !APPSTORE
import SwiftUI
import AppKit
import AVFoundation

// MARK: - ClassHistoryView
// Past classes: pick one on the left, read it on the right. This lives in a
// normal window rather than the notch — notes and a chat simply do not fit in
// a 640-point island.

struct ClassHistoryView: View {
    @StateObject private var model = ClassHistoryModel()

    var body: some View {
        NavigationSplitView {
            List(model.classes, selection: $model.selectedId) { meta in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(meta.language.label)
                        Text("·")
                        Text(ClassRecorder.dateFormatter.string(from: meta.startedAt))
                        Text("·")
                        Text(ClassRecorder.timecode(meta.duration))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(meta.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if model.classes.isEmpty {
                    ContentUnavailableView("Ninguna clase todavía",
                                           systemImage: "headphones",
                                           description: Text("Empieza una desde el menú de Coucou."))
                }
            }
        } detail: {
            if let meta = model.selected {
                ClassDetailView(meta: meta, model: model)
                    .id(meta.id)
            } else {
                Text("Elige una clase")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear { model.reload() }
    }
}

// MARK: - Model

@MainActor
final class ClassHistoryModel: ObservableObject {
    @Published var classes: [ClassMeta] = []
    @Published var selectedId: String?

    var selected: ClassMeta? { classes.first { $0.id == selectedId } }

    func reload() {
        classes = ClassStore.shared.allClasses()
        if selectedId == nil || !classes.contains(where: { $0.id == selectedId }) {
            selectedId = classes.first?.id
        }
    }

    func delete(_ meta: ClassMeta) {
        try? ClassStore.shared.delete(meta.id)
        reload()
    }
}

// MARK: - Detail

private enum DetailTab: String, CaseIterable {
    case notes = "Apuntes"
    case transcript = "Transcripción"
    case chat = "Preguntar"
}

struct ClassDetailView: View {
    let meta: ClassMeta
    @ObservedObject var model: ClassHistoryModel

    @State private var tab: DetailTab = .notes
    @StateObject private var player = ClassAudioPlayer()
    @ObservedObject private var generator = ClassNotesGenerator.shared
    @ObservedObject private var retranscriber = ClassRetranscriber.shared
    @State private var notes: ClassNotesDoc?
    @State private var transcript: [TranscriptSegment] = []
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.vertical, 8)

            switch tab {
            case .notes:      notesTab
            case .transcript: transcriptTab
            case .chat:       ClassChatView(meta: meta)
            }
        }
        .onAppear(perform: load)
        .onDisappear { player.stop() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(meta.title).font(.system(size: 17, weight: .semibold))
                Spacer()
                Menu("Exportar") {
                    Button("Carpeta…") { export(zip: false) }
                    Button("Zip…")     { export(zip: true) }
                }
                .frame(width: 110)
                Button("Mostrar en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ClassStore.shared.metaURL(for: meta.id)])
                }
            }
            HStack(spacing: 8) {
                Text("\(meta.language.label) · \(ClassRecorder.dateFormatter.string(from: meta.startedAt)) · \(ClassRecorder.timecode(meta.duration))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if let message = exportMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ClassPlayerBar(player: player, url: ClassStore.shared.audioURL(for: meta.id))
        }
        .padding(14)
    }

    // MARK: Notes

    @ViewBuilder
    private var notesTab: some View {
        // Bound to a different name: `if let notes` would shadow the @State
        // property, and the regenerate button below assigns to it.
        if let currentNotes = notes {
            ScrollView {
                ClassNotesBody(notes: currentNotes, player: player)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button(generator.isGenerating ? "Generando…" : "Regenerar apuntes") {
                        Task {
                            notes = await ClassNotesGenerator.shared.generate(for: meta)
                        }
                    }
                    .disabled(generator.isGenerating)
                }
                .padding(10)
            }
        } else {
            VStack(spacing: 10) {
                if case .failed(let message) = generator.state {
                    Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Text(transcript.isEmpty
                     ? "Esta clase no tiene transcripción, así que todavía no hay apuntes."
                     : "Esta clase no tiene apuntes todavía.")
                    .foregroundStyle(.secondary)
                Button(generator.isGenerating ? "Generando…" : "Generar apuntes") {
                    Task { notes = await ClassNotesGenerator.shared.generate(for: meta) }
                }
                .disabled(generator.isGenerating || transcript.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptTab: some View {
        if transcript.isEmpty {
            VStack(spacing: 10) {
                if case .failed(let message) = retranscriber.state {
                    Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Text("Esta clase no se transcribió.")
                    .foregroundStyle(.secondary)
                // The audio is always kept, so a failed transcription is
                // recoverable — this is the way back.
                Button(retranscriber.isRunning(meta.id) ? "Transcribiendo…" : "Transcribir el audio guardado") {
                    Task {
                        if let doc = await ClassRetranscriber.shared.retranscribe(meta) {
                            transcript = doc.segments
                        }
                    }
                }
                .disabled(retranscriber.isBusy)
                Text("Al rehacerla desde el audio no se puede distinguir quién habla: la grabación mezcla las dos fuentes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(transcript) { segment in
                        Button {
                            player.seek(to: segment.start)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ClassRecorder.timecode(segment.start))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .trailing)
                                Text(label(for: segment.speaker))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(segment.speaker == .yo ? Color.purple : Color.teal)
                                    .frame(width: 46, alignment: .leading)
                                Text(segment.text)
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    private func label(for speaker: ClassSpeaker) -> String {
        switch speaker {
        case .clase: return "Clase"
        case .yo: return "Yo"
        case .desconocido: return "—"
        }
    }

    // MARK: Actions

    private func load() {
        notes = ClassStore.shared.load(ClassNotesDoc.self, from: ClassStore.shared.notesURL(for: meta.id))
        transcript = ClassStore.shared.loadTranscript(meta.id)?.segments ?? []
    }

    private func export(zip: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Exportar aquí"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let written = zip
                ? try ClassExporter.exportZip(meta, to: destination)
                : try ClassExporter.exportFolder(meta, to: destination)
            exportMessage = "Exportado a \(written.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([written])
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}
#endif
