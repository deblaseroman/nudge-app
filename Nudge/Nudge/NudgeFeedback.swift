//
//  NudgeFeedback.swift
//  Nudge
//
//  Every haptic and animation in the app. Never call UIImpactFeedbackGenerator
//  directly from a View. Never hardcode animation durations.
//

import SwiftUI
import UIKit

// MARK: - Haptic Engine

struct NudgeHaptics {

    /// Light tap — chip select, toggle, minor UI
    static func light() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare(); g.impactOccurred()
    }

    /// Medium — button press, send message, confirm action
    static func medium() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare(); g.impactOccurred()
    }

    /// Heavy — reserved for task completion only
    static func heavy() {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare(); g.impactOccurred()
    }

    /// Success pattern — all tasks done, streak milestone, Pro upgrade confirmed
    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.prepare(); g.notificationOccurred(.success)
    }

    /// Error — cap reached, form validation fail
    static func error() {
        let g = UINotificationFeedbackGenerator()
        g.prepare(); g.notificationOccurred(.error)
    }

    /// Selection — time picker scroll, reschedule chip change
    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare(); g.selectionChanged()
    }

    /// Task complete — signature Nudge moment
    /// Two-stage: soft tap on press, full heavy thud on release
    static func taskComplete() {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare()
        g.impactOccurred(intensity: 0.65)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            g.impactOccurred(intensity: 1.0)
        }
    }
}

// MARK: - Task Completion Animation

/// The most important UX moment in the app. Apply to every task row.
struct TaskCompletionEffect: ViewModifier {
    @Binding var isComplete: Bool
    @State private var rowOpacity: Double = 1.0
    @State private var showParticles: Bool = false

    func body(content: Content) -> some View {
        content
            .opacity(rowOpacity)
            .overlay(
                ParticleBurstView(isActive: $showParticles)
                    .allowsHitTesting(false)
            )
            .onChange(of: isComplete) { _, newValue in
                guard newValue else { return }
                NudgeHaptics.taskComplete()
                showParticles = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        rowOpacity = 0.3
                    }
                }
            }
    }
}

/// Checkbox bounce — spring scale on the checkbox circle itself
struct CheckboxBounceEffect: ViewModifier {
    @Binding var isComplete: Bool
    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: isComplete) { _, newValue in
                guard newValue else { scale = 1.0; return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.4)) {
                    scale = 1.45
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.65)) {
                        scale = 1.0
                    }
                }
            }
    }
}

/// Strike-through line that draws itself across the task title
struct AnimatedStrikethrough: View {
    @Binding var isVisible: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(NudgeTheme.textMuted)
                .frame(width: geo.size.width * progress, height: 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: geo.size.height / 2)
        }
        .onChange(of: isVisible) { _, newValue in
            if newValue {
                withAnimation(.easeOut(duration: 0.28).delay(0.08)) {
                    progress = 1.0
                }
            } else {
                progress = 0
            }
        }
    }
}

/// Coral particle burst — 6 dots radiating from the checkbox on completion
struct ParticleBurstView: View {
    @Binding var isActive: Bool
    @State private var particles: [Particle] = []

    struct Particle: Identifiable {
        let id = UUID()
        var offset: CGSize = .zero
        var opacity: Double = 0
        var scale: CGFloat = 0
        let angle: Double
        let color: Color
    }

    var body: some View {
        ZStack {
            ForEach(particles) { p in
                Circle()
                    .fill(p.color)
                    .frame(width: 7, height: 7)
                    .scaleEffect(p.scale)
                    .offset(p.offset)
                    .opacity(p.opacity)
            }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue { burst() }
        }
    }

    private func burst() {
        let colors: [Color] = [
            NudgeTheme.primary, NudgeTheme.yellow,
            NudgeTheme.success, NudgeTheme.primaryLight,
            NudgeTheme.primary, NudgeTheme.yellow
        ]
        particles = (0..<6).map { i in
            Particle(angle: Double(i) * 60.0, color: colors[i])
        }
        withAnimation(.easeOut(duration: 0.45)) {
            for i in particles.indices {
                let rad = particles[i].angle * .pi / 180
                let dist: CGFloat = 32
                particles[i].offset = CGSize(
                    width: cos(rad) * dist,
                    height: sin(rad) * dist
                )
                particles[i].scale = 1.0
                particles[i].opacity = 1.0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeIn(duration: 0.22)) {
                for i in particles.indices {
                    particles[i].opacity = 0
                    particles[i].scale = 0.2
                }
            }
        }
    }
}

// MARK: - View Extensions

extension View {
    func taskCompletionEffect(isComplete: Binding<Bool>) -> some View {
        modifier(TaskCompletionEffect(isComplete: isComplete))
    }

    func checkboxBounce(isComplete: Binding<Bool>) -> some View {
        modifier(CheckboxBounceEffect(isComplete: isComplete))
    }
}

// MARK: - Animation Constants
// Use these everywhere. Never hardcode durations. Never use .default.

struct NudgeAnimation {
    /// Standard spring for most state changes
    static let standard = Animation.spring(response: 0.3, dampingFraction: 0.7)

    /// Snappy spring for small elements (chips, checkboxes)
    static let snappy = Animation.spring(response: 0.2, dampingFraction: 0.6)

    /// Gentle ease for fades and opacity
    static let gentle = Animation.easeInOut(duration: 0.2)

    /// Progress bar (onboarding step advance)
    static let progress = Animation.easeInOut(duration: 0.4)

    /// Sheet entrance
    static let sheet = Animation.spring(response: 0.4, dampingFraction: 0.75)
}
