import AppKit

/// A click-through, public-AppKit overlay that gives a peripheral visual nudge
/// without muting, ducking, or otherwise interfering with focus audio.
///
/// The glow never snaps on or off: `show` sets a *target* brightness and a
/// small timer eases the window's alpha towards it, so a slouch is noticed as
/// a slow warming of the screen edge rather than a flash.
final class PostureOverlayController {
    var enabled = true {
        didSet {
            if !enabled { hide(animated: false) }
        }
    }

    /// Multiplier for the glow's opacity. Expected range: 0.2 ... 1.0.
    var strength: Double = 0.55

    /// How long a full-strength glow takes to appear. Slow on purpose: the cue
    /// should register peripherally, not startle.
    var fadeInDuration: TimeInterval = 2.5
    /// Recovery should feel rewarding, so the glow leaves faster than it came.
    var fadeOutDuration: TimeInterval = 1.0

    private var windows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?

    // MARK: Fade state

    /// 0...1 position along the fade; the only value the timer animates.
    private var progress: Double = 0
    /// Brightness (0...1, already scaled by `strength`) the fade is heading to.
    private var targetAlpha: Double = 0
    /// Last non-zero target, so a fade-out dims *from* the brightness that was
    /// showing instead of collapsing to zero on the first tick.
    private var fadeOutFromAlpha: Double = 0
    private var fadeTimer: Timer?
    private var lastTick: Date?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.windows.contains(where: { $0.isVisible }) else { return }
            self.rebuildWindows()
        }
    }

    deinit {
        fadeTimer?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    /// Shows a warm edge glow on every display. Intensity is normalized 0...1.
    /// Safe to call on every motion sample: it only retargets the fade.
    func show(intensity: Double) {
        guard enabled else {
            hide(animated: false)
            return
        }

        let normalized = min(1, max(0, intensity))
        guard normalized > 0.01 else {
            hide()
            return
        }

        ensureWindows()
        targetAlpha = normalized * strength
        fadeOutFromAlpha = targetAlpha
        for window in windows where !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        startFadeTimer()
    }

    /// Fades the glow out (or removes it instantly when `animated` is false).
    func hide(animated: Bool = true) {
        targetAlpha = 0
        guard animated, windows.contains(where: { $0.isVisible }) else {
            stopFadeTimer()
            progress = 0
            windows.forEach { $0.orderOut(nil) }
            return
        }
        startFadeTimer()
    }

    // MARK: Fade animation

    private func startFadeTimer() {
        guard fadeTimer == nil else { return }
        lastTick = Date()
        // `.common` keeps the fade running while a menu or the popover is open.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func stopFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        lastTick = nil
    }

    private func tick() {
        let now = Date()
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now

        let fadingIn = targetAlpha > 0
        let duration = max(0.05, fadingIn ? fadeInDuration : fadeOutDuration)
        let step = dt / duration
        progress = fadingIn ? min(1, progress + step) : max(0, progress - step)

        // Ease in and out (smoothstep) so the onset is gentle rather than linear.
        let eased = progress * progress * (3 - 2 * progress)
        let alpha = CGFloat(eased * (fadingIn ? targetAlpha : fadeOutFromAlpha))
        windows.forEach { $0.alphaValue = alpha }

        let settled = fadingIn ? progress >= 1 : progress <= 0
        if settled {
            stopFadeTimer()
            if !fadingIn {
                windows.forEach { $0.orderOut(nil) }
            }
        }
    }

    // MARK: Windows

    private func ensureWindows() {
        if windows.count != NSScreen.screens.count {
            rebuildWindows()
        }
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map(makeWindow)
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.level = .statusBar
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.contentView = EdgeGlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        return window
    }
}

/// Draws several translucent inset strokes. This is intentionally peripheral:
/// the centre of the screen remains completely untouched and readable.
///
/// The view is drawn once at full brightness; all intensity and fading is done
/// through the window's alpha so nothing is re-rasterised per motion sample.
private final class EdgeGlowView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let warm = NSColor(calibratedRed: 1.0, green: 0.43, blue: 0.08, alpha: 1)
        let bands = 14
        for index in 0..<bands {
            let progress = CGFloat(index) / CGFloat(bands)
            let inset = CGFloat(index) * 2.4
            let alpha = (1 - progress) * 0.13
            warm.withAlphaComponent(alpha).setStroke()

            let rect = bounds.insetBy(dx: inset + 1, dy: inset + 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            path.lineWidth = 4.8
            path.stroke()
        }
    }
}
