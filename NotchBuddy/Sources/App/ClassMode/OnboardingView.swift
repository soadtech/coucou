#if !APPSTORE
import SwiftUI

// MARK: - OnboardingView
// First run, in the notch. Three screens introducing Mochi, then the choice
// that actually matters: with AI or without.
//
// Nothing here promises what the app does not do. "Te recordaré cosas
// importantes" became "los momentos que marques", because reminders are not
// built and an onboarding that oversells is worse than one that undersells.

struct OnboardingView: View {
    @ObservedObject private var state = AppState.shared
    @State private var step = 0
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private struct Slide {
        let title: String
        let body: String
    }

    private let slides = [
        Slide(title: "Soy Mochi, tu asistente para tus reuniones",
              body: "Vivo aquí arriba, en el notch. Asómate cuando quieras."),
        Slide(title: "Grabaré tus reuniones y te dejaré los apuntes",
              body: "Resumen, vocabulario, lo que te corrijan y los momentos que marques como importantes o que no entendiste. Todo se transcribe en este Mac."),
        Slide(title: "Y podrás preguntarme por chat",
              body: "Sobre una reunión concreta o sobre todas a la vez: qué se dijo, qué repites, qué deberías repasar."),
    ]

    var body: some View {
        ZStack {
            CardBackground(wash: .indigo)
            Group {
                if step < slides.count { slide(slides[step]) } else { keyStep }
            }
            .padding(.leading, 148)
            .padding(.trailing, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Slides

    private func slide(_ slide: Slide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            Text(slide.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .fixedSize(horizontal: false, vertical: true)
            Text(slide.body)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#B9BDC5"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach(0..<slides.count, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(index == step ? 0.8 : 0.22))
                        .frame(width: 5, height: 5)
                }
                Spacer()
                if step > 0 {
                    SecondaryButton("Atrás") { step -= 1 }
                }
                PrimaryButton("Siguiente") { step += 1 }
            }
        }
    }

    // MARK: The choice that matters

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("¿Quieres que además piense por ti?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text("Grabar y transcribir funciona sin nada: es todo local. Los apuntes y el chat necesitan una API key de Gemini. Solo se envía texto; el audio nunca sale de este Mac.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#B9BDC5"))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecureField("API key de Gemini", text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .focused($focused)
                    .onSubmit(saveKey)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#F4505E"))
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                SecondaryButton("Atrás") { step -= 1 }
                Spacer()
                SecondaryButton("Seguir sin IA") { finish() }
                PrimaryButton(checking ? "Comprobando…" : "Guardar y empezar") { saveKey() }
            }
        }
        .onAppear { focused = true }
    }

    // MARK: Actions

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Escribe la key, o elige seguir sin IA."
            return
        }
        guard !checking else { return }
        checking = true
        error = nil
        Task {
            // Checked before it is stored: better to fail here than halfway
            // through generating notes for a real meeting.
            let result = await GeminiService.shared.validate(key: trimmed)
            checking = false
            switch result {
            case .success:
                finish()
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private func finish() {
        state.hasOnboarded = true
        NotificationCenter.default.post(name: .islandShowClassHome, object: nil)
    }
}
#endif
