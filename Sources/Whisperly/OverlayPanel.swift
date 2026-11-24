import AppKit
import QuartzCore

/// Live voice bars. Animated at 60 fps: bars peak in the middle, each one
/// flickers on its own rhythm while you speak, and a soft travelling wave
/// keeps them moving during pauses. Grey → white as the voice gets louder.
final class WaveformView: NSView {
    private let barCount = 11
    private let barWidth: CGFloat = 2

    private var heights: [CGFloat]          // what's drawn, 0…1
    private var inputLevel: CGFloat = 0     // latest mic level, 0…1
    private var displayLevel: CGFloat = 0   // smoothed mic level
    private var phase: Double = 0

    private static let dim = NSColor(calibratedWhite: 0.5, alpha: 1)
    private static let bright = NSColor(calibratedWhite: 1.0, alpha: 1)

    init() {
        heights = Array(repeating: 0, count: barCount)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func push(_ level: CGFloat) {
        inputLevel = max(0, min(1, level))
    }

    func reset() {
        inputLevel = 0
        displayLevel = 0
        phase = 0
        heights = Array(repeating: 0, count: barCount)
        needsDisplay = true
    }

    /// Advance one frame (called at 60 fps by the panel).
    func tick(dt: Double) {
        phase += dt

        // Fast attack, slower release, so syllables "pop" and fall gracefully.
        let k: CGFloat = inputLevel > displayLevel ? 0.55 : 0.10
        displayLevel += (inputLevel - displayLevel) * k

        let center = CGFloat(barCount - 1) / 2
        for i in 0..<barCount {
            let d = abs(CGFloat(i) - center) / center           // 0 middle … 1 edge
            let envelope = 1 - 0.6 * d * d                       // taller in the middle
            let speed = 6.0 + Double(i % 4) * 1.7                // each bar its own rhythm
            let wobble = CGFloat(0.5 + 0.5 * sin(phase * speed + Double(i) * 1.9))
            let voiced = displayLevel * envelope * (0.45 + 0.55 * wobble)
            // Gentle wave rolling across the bars when it's quiet.
            let idle = 0.12 + 0.26 * CGFloat(0.5 + 0.5 * sin(phase * 4.0 - Double(i) * 0.65))
            let target = max(idle * envelope, voiced)

            let ease: CGFloat = target > heights[i] ? 0.45 : 0.16
            heights[i] += (target - heights[i]) * ease
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap = (bounds.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
        for (i, level) in heights.enumerated() {
            let h = max(2, level * bounds.height)
            let x = CGFloat(i) * (barWidth + gap)
            let y = (bounds.height - h) / 2
            let color = Self.dim.blended(withFraction: min(1, level * 1.3), of: Self.bright) ?? Self.dim
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                         xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

/// Small black capsule just above the Dock, shown only while Fn is held.
/// Opens outward from the centre (left and right, with a slight spring)
/// and closes back into the centre on release.
final class OverlayPanel {
    private var panel: NSPanel?
    private let pill = NSView()
    private let waveform = WaveformView()

    private let pillSize = NSSize(width: 64, height: 24)
    private let waveSize = NSSize(width: 38, height: 14)
    private let overshootRoom: CGFloat = 8          // window slack for the spring

    // Open/close animation state. progress: 0 = closed dot, 1 = full pill.
    private var progress: CGFloat = 0
    private var animFrom: CGFloat = 0
    private var animTo: CGFloat = 0
    private var animStart: CFTimeInterval = 0
    private var animDuration: Double = 0
    private var opening = false
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    /// Hidden slow-motion knob for testing: `defaults write com.ryangiang.whisperly pillAnimationScale 10`
    private var slowdown: Double {
        let v = UserDefaults.standard.double(forKey: "pillAnimationScale")
        return v > 0 ? v : 1
    }

    func showRecording() {
        if panel == nil { build() }
        guard let panel else { return }
        waveform.reset()
        if !panel.isVisible {
            progress = 0
            panel.setFrame(windowFrame(), display: false)
            apply()
            panel.orderFrontRegardless()
        }
        startAnimation(to: 1, duration: 0.34, opening: true)
    }

    func pushLevel(_ level: CGFloat) {
        waveform.push(level)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        startAnimation(to: 0, duration: 0.24, opening: false)
    }

    // MARK: - Animation

    private func startAnimation(to target: CGFloat, duration: Double, opening: Bool) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            progress = target
            apply()
            if target == 0 { finishClose() } else { startTimer() }
            return
        }
        animFrom = progress
        animTo = target
        animStart = CACurrentMediaTime()
        animDuration = duration * slowdown
        self.opening = opening
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        waveform.tick(dt: (now - lastTick) / slowdown)
        lastTick = now

        if animFrom != animTo {
            let t = min(1, (now - animStart) / max(animDuration, 0.001))
            let eased = opening ? Self.easeOutBack(t) : Self.easeInOutCubic(t)
            progress = animFrom + (animTo - animFrom) * CGFloat(eased)
            apply()
            if t >= 1 {
                progress = animTo
                animFrom = animTo
                apply()
                if animTo == 0 { finishClose() }
            }
        }
    }

    private func finishClose() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    /// Lays out the pill for the current progress.
    private func apply() {
        guard let panel else { return }
        let bounds = panel.contentView?.bounds ?? .zero
        let width = pillSize.height + (pillSize.width - pillSize.height) * progress
        pill.frame = NSRect(x: (bounds.width - width) / 2, y: 0,
                            width: width, height: pillSize.height)
        waveform.frame = NSRect(x: (width - waveSize.width) / 2,
                                y: (pillSize.height - waveSize.height) / 2,
                                width: waveSize.width, height: waveSize.height)
        pill.alphaValue = min(1, max(0, progress * 2.5))
        waveform.alphaValue = min(1, max(0, (progress - 0.35) / 0.5))
        panel.invalidateShadow()
    }

    private static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.3, c3 = c1 + 1
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }

    private static func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: - Setup

    private func build() {
        let panel = NSPanel(contentRect: windowFrame(),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: windowFrame().size))
        content.wantsLayer = true

        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.94).cgColor
        pill.layer?.cornerRadius = pillSize.height / 2
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor
        pill.layer?.masksToBounds = true    // capsule edges reveal the bars as it opens

        pill.addSubview(waveform)
        content.addSubview(pill)
        panel.contentView = content

        self.panel = panel
    }

    /// Window: full pill width plus spring slack, bottom-centre above the Dock.
    private func windowFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let width = pillSize.width + overshootRoom * 2
        return NSRect(x: screen.midX - width / 2,
                      y: screen.minY + 14,
                      width: width,
                      height: pillSize.height)
    }
}
