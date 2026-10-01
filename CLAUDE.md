# Coucou — guide for AI coding agents

Coucou is a native macOS app: Mochi, a small animated character living in the MacBook notch, shows Claude Code sessions and a few integrations, and lets the user approve, answer, chat and drop files from the notch.

## Where things are
- `NotchBuddy/Sources/App/` — all Swift code. `NotchBuddy/Resources/sounds/` — the 28 WAV sounds. `NotchBuddy/project.yml` — XcodeGen project (never edit the `.xcodeproj` by hand).
- `docs/SPEC.md`, `docs/INTEGRATIONS.md` — behaviour, views, states, integrations (in French).
- `design/prototype/notch-buddy.html` — original prototype, the visual source of truth. `design/captures/` — target screenshots.
- `docs/*.html` — the GitHub Pages site (privacy, terms, support, legal notice).

## Build
```
cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build
```

## Class Mode

Mochi listens to the user's online language classes, transcribes them on this
Mac and turns them into study notes. Everything lives in
`NotchBuddy/Sources/App/ClassMode/`, wrapped in `#if !APPSTORE` — the App Store
target is sandboxed, where neither the capture nor the model download works.

- **Capture.** App audio through `ScreenCaptureKit` (`AppAudioCapture`),
  microphone separately through `AVAudioEngine` (`MicCapture`), mixed into
  `audio.m4a` at 48 kHz by `ClassAudioWriter`. Core Audio process taps were
  tried first and abandoned: they declared a sample rate the stream did not
  honour, and it changed mid-recording when a Bluetooth headset switched
  profile.
- **Transcription.** WhisperKit via SPM — the project's only third-party
  dependency, accepted for this — behind the `TranscriptionEngine` protocol so
  nothing else imports it. No fixed language: a class mixes Spanish, English and
  French, so every chunk is detected on its own. Chunks are cut at silence, and
  near-silent audio is never sent (given silence Whisper invents stock phrases).
- **Notes and Q&A.** `ClassNotesGenerator` and `ClassChat` go through
  `ClaudeService.complete()`, reusing the existing Keychain key. Explanations
  are in Spanish at A2 level.
- **Storage.** `~/Library/Application Support/Coucou/Classes/<id>/` with
  `audio.m4a`, `transcript.json`, `notes.json`, `notes.md`, `marks.json`,
  `meta.json`. The export format is a separate, versioned contract documented in
  `docs/class-mode-schema.md` — do not change it without bumping
  `formatVersion`.

### Rules specific to Class Mode

- **Audio never leaves the Mac.** Only text goes to the Anthropic API, and only
  when generating notes or answering a question.
- **The recording indicator is visible whenever audio is being captured**, down
  to the island's smallest size.
- **Never let transcription failures stop a recording.** The audio is the part
  that cannot be recovered; a transcript can always be rebuilt from it with
  `ClassRetranscriber`.
- **Never let the model quote the transcript.** Excerpts around marked moments
  are extracted locally; only the explanation is generated.
- Known gaps are tracked in `docs/PENDIENTES.md`. Read it before changing
  anything here.

### Debug builds

Xcode signs Debug ad-hoc, and macOS ties TCC grants (Screen Recording,
Microphone) to the binary when there is no team — so every rebuild asks for
permissions again. Run `scripts/sign-debug.sh` after building. Also verify the
App Store target with a separate `-derivedDataPath`: both targets produce
`Coucou.app` in the same folder and silently overwrite each other.

## Rules
- Swift 6, SwiftUI + AppKit. No third-party dependencies unless truly unavoidable. The character is drawn in code (`Canvas` + `TimelineView`), no Rive/Lottie/images.
- Secrets live in the Keychain, never on disk or in git.
- No telemetry. Network calls only to services the user configured.
- Never block Claude Code: if the app doesn't answer, the hook exits immediately.
- Never overwrite `~/.claude/settings.json`: dated backup, merge, show the diff, write only after the user confirms.
- Never send an email or approve a Claude Code permission without an explicit click.
- Performance: 0 % CPU when the island is hidden.
- Keep the bundle identifier `fr.louisraille.NotchBuddy` (Keychain items, preferences and permissions depend on it).
- Visual changes must match the prototype and the screenshots in `design/captures/`.
