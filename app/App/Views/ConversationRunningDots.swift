import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Three dots under the last thing a running turn shows. The strong dot steps
/// from left to right every 0.4 s. Core Animation runs the steps, so nothing in
/// the transcript is evaluated or laid out again while they move. The dots
/// stand still at one strength under Reduce Motion, and stop while the window
/// is not visible. VoiceOver skips them: the turn's "Working" label says it runs.
struct ConversationRunningDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationAnimationsPaused) private var paused

    var body: some View {
        RunningDots(reduceMotion: reduceMotion, paused: paused)
            .frame(width: RunningDotsView.width, height: RunningDotsView.diameter)
            // Centred in the work rows' 17 pt icon column.
            .frame(width: 17)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// The page is out of sight though still in the window, as a tab kept alive
    /// behind the one showing: the dots stand still, so nothing animates unseen.
    @Entry var conversationAnimationsPaused = false
}

#if os(macOS)
private struct RunningDots: NSViewRepresentable {
    let reduceMotion: Bool
    /// The window's occlusion already pauses them on a Mac.
    let paused: Bool

    func makeNSView(context: Context) -> RunningDotsView { RunningDotsView() }

    func updateNSView(_ view: RunningDotsView, context: Context) {
        view.reduceMotion = reduceMotion
    }
}

/// A layer-hosting view: it owns its layers, and the window server plays
/// their opacity keyframes without calling back into the app.
private final class RunningDotsView: NSView {
    static let diameter: CGFloat = 4
    static let gap: CGFloat = 3
    static let width = diameter * 3 + gap * 2

    private let dots = (0..<3).map { _ in CALayer() }

    var reduceMotion = false {
        didSet { if reduceMotion != oldValue { updateAnimation() } }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.diameter))
        let root = CALayer()
        layer = root
        wantsLayer = true
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * (Self.diameter + Self.gap), y: 0,
                               width: Self.diameter, height: Self.diameter)
            dot.cornerRadius = Self.diameter / 2
            root.addSublayer(dot)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateColor()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    @objc private func occlusionChanged() { updateAnimation() }

    private func updateColor() {
        var color = WovenColors.mutedForeground.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = WovenColors.mutedForeground.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots { dot.backgroundColor = color }
        CATransaction.commit()
    }

    private func updateAnimation() {
        RunningDotsView.animate(dots, animates: !reduceMotion && window?.occlusionState.contains(.visible) == true,
                                reduceMotion: reduceMotion)
    }
}
#else
private struct RunningDots: UIViewRepresentable {
    let reduceMotion: Bool
    let paused: Bool

    func makeUIView(context: Context) -> RunningDotsView { RunningDotsView() }

    func updateUIView(_ view: RunningDotsView, context: Context) {
        view.reduceMotion = reduceMotion
        view.paused = paused
    }
}

private final class RunningDotsView: UIView {
    static let diameter: CGFloat = 4
    static let gap: CGFloat = 3
    static let width = diameter * 3 + gap * 2

    private let dots = (0..<3).map { _ in CALayer() }

    var reduceMotion = false {
        didSet { if reduceMotion != oldValue { updateAnimation() } }
    }

    var paused = false {
        didSet { if paused != oldValue { updateAnimation() } }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.diameter))
        isUserInteractionEnabled = false
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * (Self.diameter + Self.gap), y: 0,
                               width: Self.diameter, height: Self.diameter)
            dot.cornerRadius = Self.diameter / 2
            layer.addSublayer(dot)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in view.updateColor() }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateColor()
        updateAnimation()
    }

    private func updateColor() {
        let color = WovenColors.mutedForeground.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots { dot.backgroundColor = color }
        CATransaction.commit()
    }

    private func updateAnimation() {
        RunningDotsView.animate(dots, animates: !reduceMotion && !paused && window != nil, reduceMotion: reduceMotion)
    }
}
#endif

extension RunningDotsView {
    private static let step: CFTimeInterval = 0.4
    private static let faint: Float = 0.25
    private static let animationKey = "step"

    /// One discrete keyframe animation per dot, added in one transaction so the
    /// three share a start; each dot's offset puts its strong step in turn.
    static func animate(_ dots: [CALayer], animates: Bool, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.opacity = reduceMotion || index == 0 ? 1 : Self.faint
            if !animates {
                dot.removeAnimation(forKey: Self.animationKey)
            } else if dot.animation(forKey: Self.animationKey) == nil {
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.calculationMode = .discrete
                animation.values = [1, Self.faint]
                animation.keyTimes = [0, NSNumber(value: 1.0 / 3), 1]
                animation.duration = Self.step * 3
                animation.timeOffset = Double((3 - index) % 3) * Self.step
                animation.repeatCount = .infinity
                animation.isRemovedOnCompletion = false
                dot.add(animation, forKey: Self.animationKey)
            }
        }
        CATransaction.commit()
    }
}
