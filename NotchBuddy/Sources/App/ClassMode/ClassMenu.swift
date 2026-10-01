#if !APPSTORE
import AppKit

// MARK: - ClassMenu
// The "Modo Clase" submenu in the menu bar. Rebuilt every time it opens so the
// list of apps currently emitting audio is always fresh.

@MainActor
final class ClassMenu: NSObject, NSMenuDelegate {

    let menuItem: NSMenuItem
    private let submenu = NSMenu()

    override init() {
        menuItem = NSMenuItem(title: "Modo Clase", action: nil, keyEquivalent: "")
        super.init()
        submenu.delegate = self
        menuItem.submenu = submenu
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recorder = ClassRecorder.shared

        if recorder.isRecording {
            let title = recorder.currentClass?.title ?? "Clase"
            let header = NSMenuItem(title: "\(title) — \(ClassRecorder.timecode(recorder.elapsed))",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            // Live transcription state. The island shows this properly in
            // phase 3; the menu is how it can be checked before then.
            let transcriber = recorder.transcriber
            let count = transcriber.segments.count
            let status = transcriber.isTranscribing ? "transcribiendo…" : "\(count) frases"
            let statusItem = NSMenuItem(title: "  \(status)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            for segment in transcriber.recentSegments {
                let who = segment.speaker == .clase ? "Clase" : "Yo"
                let text = segment.text.count > 60
                    ? String(segment.text.prefix(60)) + "…"
                    : segment.text
                let line = NSMenuItem(title: "  \(who): \(text)", action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
            if let error = transcriber.lastError {
                let line = NSMenuItem(title: "  ⚠︎ \(error)", action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }

            menu.addItem(.separator())
            menu.addItem(item(title: "Ver en el notch", action: #selector(showInNotch)))
            menu.addItem(item(title: "Marcar: no lo entendí", action: #selector(markNotUnderstood)))
            menu.addItem(item(title: "Marcar: importante", action: #selector(markImportant)))
            menu.addItem(.separator())
            menu.addItem(item(title: "Parar la clase", action: #selector(stopClass)))
            menu.addItem(.separator())
            menu.addItem(item(title: "Mis clases…", action: #selector(showHistory)))
        } else {
            // Listing apps is async (ScreenCaptureKit), so the menu shows what
            // the last refresh found and kicks off another one for next time.
            if !hasPermission && !forceList {
                let note = NSMenuItem(title: "Falta permiso de Grabación de pantalla",
                                      action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
                menu.addItem(item(title: "Conceder permiso…", action: #selector(requestScreenRecording)))
                menu.addItem(item(title: "Abrir Ajustes del Sistema…",
                                  action: #selector(openScreenRecordingSettings)))
                // The preflight check can say no while the permission is in
                // fact granted — an ad-hoc signed build changes identity on
                // every rebuild, so System Settings shows a stale entry. Never
                // let that lock the user out of their own app.
                menu.addItem(item(title: "Buscar apps de todos modos",
                                  action: #selector(listAnyway)))
            } else if cachedApps.isEmpty {
                let loading = NSMenuItem(title: "Buscando apps…", action: nil, keyEquivalent: "")
                loading.isEnabled = false
                menu.addItem(loading)
            } else {
                menu.addItem(item(title: "Empezar una clase…", action: #selector(showStart)))
            menu.addItem(item(title: "Mis clases…", action: #selector(showHistory)))

            // Last class: notes state and a way at them.
            if let last = ClassStore.shared.allClasses().first(where: { $0.isComplete }) {
                menu.addItem(.separator())
                let header = NSMenuItem(title: "Última clase: \(last.title)",
                                        action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)

                if ClassNotesGenerator.shared.isGenerating {
                    let note = NSMenuItem(title: "  Generando apuntes…", action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    menu.addItem(note)
                } else if FileManager.default.fileExists(atPath: ClassStore.shared.notesMarkdownURL(for: last.id).path) {
                    menu.addItem(item(title: "Abrir apuntes", action: #selector(openNotes)))
                    menu.addItem(item(title: "Regenerar apuntes", action: #selector(regenerateNotes)))
                } else {
                    menu.addItem(item(title: "Generar apuntes", action: #selector(regenerateNotes)))
                }
                menu.addItem(item(title: "Ver la carpeta de la clase", action: #selector(revealClass)))

                if case .failed(let message) = ClassNotesGenerator.shared.state {
                    let note = NSMenuItem(title: "  ⚠︎ \(message)", action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    menu.addItem(note)
                }
            }

            menu.addItem(.separator())
            let header = NSMenuItem(title: "Escuchar…", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for app in cachedApps.prefix(12) {
                    let entry = item(title: app.name, action: #selector(startWithSource(_:)))
                    entry.representedObject = SourceBox(app)
                    menu.addItem(entry)
                }
            }
            menu.addItem(.separator())
            menu.addItem(item(title: "Solo mi micrófono", action: #selector(startMicOnly)))

            switch WhisperModelManager.shared.state {
            case .ready:
                break
            case .notDownloaded:
                let note = NSMenuItem(title: "Modelo de transcripción sin descargar (Settings)",
                                      action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(.separator())
                menu.addItem(note)
            case .downloading(let progress):
                let note = NSMenuItem(title: "Descargando modelo… \(Int(progress * 100)) %",
                                      action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(.separator())
                menu.addItem(note)
            case .failed(let message):
                let note = NSMenuItem(title: "⚠︎ \(message)", action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(.separator())
                menu.addItem(note)
            }
            refresh()
        }

        if let error = recorder.lastError {
            menu.addItem(.separator())
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private var cachedApps: [AudioAppInfo] = []
    private var lastRefresh: Date = .distantPast
    private var refreshing = false
    /// Set when the user overrides a negative permission check.
    private var forceList = false

    private var hasPermission: Bool { ClassRecorder.shared.hasScreenRecordingPermission }

    /// Refreshes the app list at most every few seconds, and never without the
    /// permission — each ScreenCaptureKit call would otherwise prompt again.
    private func refresh() {
        guard hasPermission || forceList, !refreshing,
              Date().timeIntervalSince(lastRefresh) > 3 else { return }
        refreshing = true
        Task { @MainActor in
            cachedApps = await ClassRecorder.shared.availableSources()
            lastRefresh = .now
            refreshing = false
        }
    }

    private var lastClass: ClassMeta? {
        ClassStore.shared.allClasses().first { $0.isComplete }
    }

    @objc private func showHistory() {
        ClassWindowController.shared.show()
    }

    @objc private func openNotes() {
        guard let last = lastClass else { return }
        NSWorkspace.shared.open(ClassStore.shared.notesMarkdownURL(for: last.id))
    }

    @objc private func revealClass() {
        guard let last = lastClass else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ClassStore.shared.metaURL(for: last.id)])
    }

    @objc private func regenerateNotes() {
        guard let last = lastClass else { return }
        Task { _ = await ClassNotesGenerator.shared.generate(for: last) }
    }

    @objc private func showStart() {
        NotificationCenter.default.post(name: .islandShowClassStart, object: nil)
    }

    @objc private func showInNotch() {
        NotificationCenter.default.post(name: .islandShowClass, object: nil)
    }

    @objc private func markNotUnderstood() { ClassRecorder.shared.mark(.notUnderstood) }
    @objc private func markImportant()     { ClassRecorder.shared.mark(.important) }

    @objc private func listAnyway() {
        forceList = true
        lastRefresh = .distantPast
        refresh()
    }

    @objc private func requestScreenRecording() {
        ClassRecorder.shared.requestScreenRecordingPermission()
    }

    @objc private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// NSMenuItem.representedObject needs a class; AudioAppInfo is a struct.
    private final class SourceBox: NSObject {
        let source: AudioAppInfo
        init(_ source: AudioAppInfo) { self.source = source }
    }

    // MARK: Actions

    @objc private func startWithSource(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SourceBox else { return }
        let recorder = ClassRecorder.shared
        Task { await recorder.start(title: "", language: recorder.language, source: box.source) }
    }

    @objc private func startMicOnly() {
        let recorder = ClassRecorder.shared
        Task { await recorder.start(title: "", language: recorder.language, source: nil) }
    }

    @objc private func stopClass() {
        guard let meta = ClassRecorder.shared.stop() else { return }
        // The transcriber flushes its tail asynchronously; reveal the folder
        // once that has landed so transcript.json is complete.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NSWorkspace.shared.activateFileViewerSelecting([ClassStore.shared.metaURL(for: meta.id)])
        }
    }
}
#endif
