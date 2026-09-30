#if !APPSTORE
import SwiftUI

// MARK: - ClassMochiIndicator
// Headphones drawn over Mochi while a class is being captured. Drawn in code
// with Canvas, like the rest of the character — no images anywhere.
//
// It is deliberately quiet: a thin band and two cups in Mochi's own line
// weight, plus a slow pulse driven by the input level so it reads as "hearing
// something" rather than as a badge stuck on top.

struct ClassMochiIndicator: View {
    let center: CGPoint
    let diameter: CGFloat
    let level: Double

    var body: some View {
        Canvas { context, _ in
            let r = diameter / 2
            let stroke = max(1.4, diameter * 0.045)
            let colour = Color(hex: "#F4505E")

            // Band: an arc riding just above the head.
            let bandRadius = r * 1.06
            var band = Path()
            band.addArc(center: center,
                        radius: bandRadius,
                        startAngle: .degrees(196),
                        endAngle: .degrees(344),
                        clockwise: false)
            context.stroke(band, with: .color(colour.opacity(0.9)),
                           style: StrokeStyle(lineWidth: stroke, lineCap: .round))

            // Cups at both ends of the band, breathing with the input level.
            let pulse = 1 + 0.12 * min(1, max(0, level))
            let cupW = r * 0.30 * pulse
            let cupH = r * 0.46 * pulse
            for angle in [196.0, 344.0] {
                let radians = angle * .pi / 180
                let point = CGPoint(x: center.x + cos(radians) * bandRadius,
                                    y: center.y + sin(radians) * bandRadius)
                let rect = CGRect(x: point.x - cupW / 2, y: point.y - cupH / 2,
                                  width: cupW, height: cupH)
                context.fill(Path(roundedRect: rect, cornerRadius: cupW * 0.5),
                             with: .color(colour.opacity(0.9)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - ClassBotOverlay
// Wraps the indicator in something that *observes* the recorder. IslandContainer
// must not observe it: the input level republishes twice a second, and that
// would redraw the whole island each time instead of this one small Canvas.

struct ClassBotOverlay: View {
    @ObservedObject private var recorder = ClassRecorder.shared
    let center: CGPoint
    let diameter: CGFloat
    let opacity: Double

    var body: some View {
        if recorder.isRecording, diameter > 0, opacity > 0 {
            ClassMochiIndicator(center: center, diameter: diameter, level: recorder.level)
                .opacity(opacity)
        }
    }
}

// MARK: - ClassCompactSlot
// The compact island's right-hand slot: the recording indicator during a
// class, the usual mini grid otherwise.

struct ClassCompactSlot: View {
    @ObservedObject private var recorder = ClassRecorder.shared
    @ObservedObject var state: AppState

    var body: some View {
        if recorder.isRecording {
            ClassCompactBadge()
        } else {
            CompactMiniGrid(state: state)
        }
    }
}

// MARK: - ClassCompactBadge
// The recording dot and elapsed time, shown while the island is compact.

struct ClassCompactBadge: View {
    @ObservedObject private var recorder = ClassRecorder.shared

    var body: some View {
        HStack(spacing: 5) {
            RecordingDot()
            Text(ClassRecorder.timecode(recorder.elapsed))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: "#E8E9EC"))
        }
    }
}

// MARK: - ClassHiddenDot
// The recording indicator at the island's smallest size.
//
// The island must not stay expanded for a whole class: without a physical
// notch it is simply a wide black bar across the top of the screen, and an
// hour of that is unbearable. So it collapses as usual and the guarantee —
// visible whenever Coucou is listening — is kept by this dot instead.

struct ClassHiddenDot: View {
    @ObservedObject private var recorder = ClassRecorder.shared

    var body: some View {
        if recorder.isRecording {
            RecordingDot()
        }
    }
}
#endif
