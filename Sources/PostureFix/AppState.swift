import Foundation
import Combine
import ServiceManagement
import AppKit

/// One point in the live head-drop chart.
struct DeviationSample: Identifiable {
    let id: Int
    let t: Double      // seconds since the session started (chart x-axis)
    let drop: Double
}

/// Central view-model. Wires the motion stream → posture analysis → alerts,
/// tracks session stats, exposes everything the menu UI needs, and persists
/// settings to UserDefaults.
final class AppState: ObservableObject {

    let motion = HeadphoneMotionService()
    let analyzer = PostureAnalyzer()
    let alerts = AlertManager()
    let audio = AudioDeviceMonitor()
    let history = HistoryStore()
    let overlay = PostureOverlayController()

    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    // MARK: Live, observable state

    @Published private(set) var isMonitoring = false
    @Published private(set) var postureState: PostureState = .unknown
    @Published private(set) var livePitch: Double = 0
    @Published private(set) var deviation: Double = 0
    @Published private(set) var isCalibrated = false
    @Published private(set) var sessionRemainingSeconds: TimeInterval?

    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemError: String?

    // MARK: Session stats

    @Published private(set) var goodSeconds: Double = 0
    @Published private(set) var badSeconds: Double = 0
    @Published private(set) var slouchEvents = 0
    @Published private(set) var recentSamples: [DeviationSample] = []

    private var lastSampleTime: Date?
    private var lastChartTime: Date?
    private var previousState: PostureState = .unknown
    private var sampleIndex = 0
    private var sessionStartTime: Date?
    private var focusEndDate: Date?
    private let chartWindowSeconds: Double = 60

    // MARK: Settings (persisted)

    @Published var threshold: Double {
        didSet { analyzer.thresholdDegrees = threshold; defaults.set(threshold, forKey: "threshold") }
    }
    @Published var holdSeconds: Double {
        didSet { analyzer.holdSeconds = holdSeconds; defaults.set(holdSeconds, forKey: "holdSeconds") }
    }
    @Published var cooldown: Double {
        didSet { alerts.cooldown = cooldown; defaults.set(cooldown, forKey: "cooldown") }
    }
    @Published var soundEnabled: Bool {
        didSet { alerts.soundEnabled = soundEnabled; defaults.set(soundEnabled, forKey: "soundEnabled") }
    }
    @Published var soundName: String {
        didSet { alerts.soundName = soundName; defaults.set(soundName, forKey: "soundName") }
    }
    @Published var voiceEnabled: Bool {
        didSet { alerts.voiceEnabled = voiceEnabled; defaults.set(voiceEnabled, forKey: "voiceEnabled") }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            alerts.notificationEnabled = notificationsEnabled
            defaults.set(notificationsEnabled, forKey: "notificationsEnabled")
            if notificationsEnabled { alerts.requestNotificationAuthorization() }
        }
    }
    @Published var invert: Bool {
        didSet { analyzer.invert = invert; defaults.set(invert, forKey: "invert") }
    }
    @Published var visualCueEnabled: Bool {
        didSet {
            overlay.enabled = visualCueEnabled
            defaults.set(visualCueEnabled, forKey: "visualCueEnabled")
        }
    }
    @Published var visualCueStrength: Double {
        didSet {
            overlay.strength = visualCueStrength
            defaults.set(visualCueStrength, forKey: "visualCueStrength")
        }
    }
    @Published var escalationSeconds: Double {
        didSet {
            alerts.escalationSeconds = escalationSeconds
            defaults.set(escalationSeconds, forKey: "escalationSeconds")
        }
    }
    /// 0 means an untimed session, useful alongside an external Pomodoro app.
    @Published var focusDurationMinutes: Int {
        didSet { defaults.set(focusDurationMinutes, forKey: "focusDurationMinutes") }
    }

    init() {
        defaults.register(defaults: [
            "threshold": 12.0,
            "holdSeconds": 8.0,
            "cooldown": 180.0,
            "soundEnabled": false,
            "soundName": "Tink",
            "voiceEnabled": false,
            "notificationsEnabled": false,
            "invert": false,
            "visualCueEnabled": true,
            "visualCueStrength": 0.55,
            "escalationSeconds": 30.0,
            "focusDurationMinutes": 0
        ])

        threshold = defaults.double(forKey: "threshold")
        holdSeconds = defaults.double(forKey: "holdSeconds")
        cooldown = defaults.double(forKey: "cooldown")
        soundEnabled = defaults.bool(forKey: "soundEnabled")
        soundName = defaults.string(forKey: "soundName") ?? "Tink"
        voiceEnabled = defaults.bool(forKey: "voiceEnabled")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        invert = defaults.bool(forKey: "invert")
        visualCueEnabled = defaults.bool(forKey: "visualCueEnabled")
        visualCueStrength = defaults.double(forKey: "visualCueStrength")
        escalationSeconds = defaults.double(forKey: "escalationSeconds")
        focusDurationMinutes = defaults.integer(forKey: "focusDurationMinutes")

        analyzer.thresholdDegrees = threshold
        analyzer.holdSeconds = holdSeconds
        analyzer.invert = invert
        alerts.cooldown = cooldown
        alerts.soundEnabled = soundEnabled
        alerts.soundName = soundName
        alerts.voiceEnabled = voiceEnabled
        alerts.notificationEnabled = notificationsEnabled
        alerts.escalationSeconds = escalationSeconds
        overlay.enabled = visualCueEnabled
        overlay.strength = visualCueStrength
        if notificationsEnabled { alerts.requestNotificationAuthorization() }

        motion.onMotion = { [weak self] pitch in
            self?.handle(pitch: pitch)
        }

        // Re-publish nested object changes (connection / audio route) to the UI.
        motion.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        motion.$hasData
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] hasData in
                guard let self, !hasData else { return }
                self.overlay.hide()
                if self.isMonitoring {
                    self.analyzer.reset()
                    self.isCalibrated = false
                    self.postureState = .unknown
                    self.deviation = 0
                }
            }
            .store(in: &cancellables)
        audio.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Persist the in-progress session if the app quits mid-monitoring.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.overlay.hide(animated: false)
                self?.flushSessionToHistory()
            }
            .store(in: &cancellables)

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in self?.updateFocusTimer(now: now) }
            .store(in: &cancellables)

        refreshLoginItemStatus()
    }

    // MARK: Intents

    func startMonitoring() {
        resetSession()
        if focusDurationMinutes > 0 {
            let duration = TimeInterval(focusDurationMinutes * 60)
            focusEndDate = Date().addingTimeInterval(duration)
            sessionRemainingSeconds = duration
        } else {
            focusEndDate = nil
            sessionRemainingSeconds = nil
        }
        motion.start()
        isMonitoring = true
    }

    func stopMonitoring() {
        flushSessionToHistory()
        motion.stop()
        isMonitoring = false
        postureState = .unknown
        deviation = 0
        focusEndDate = nil
        sessionRemainingSeconds = nil
        overlay.hide()
    }

    func calibrate() {
        if analyzer.calibrate() {
            isCalibrated = true
            postureState = .good
            alerts.resetCooldown()
            resetSession()
        }
    }

    func recalibrate() {
        flushSessionToHistory()
        analyzer.reset()
        isCalibrated = false
        postureState = .unknown
        deviation = 0
        resetSession()
        overlay.hide()
    }

    func previewSound() {
        alerts.previewSound()
    }

    func previewVisualCue() {
        guard visualCueEnabled else { return }
        overlay.show(intensity: 0.8)
        // Hold long enough for the slow fade-in to complete before fading out.
        let holdFor = overlay.fadeInDuration + 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + holdFor) { [weak self] in
            guard let self, self.postureState != .bad else { return }
            self.overlay.hide()
        }
    }

    // MARK: Launch at login

    func refreshLoginItemStatus() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    // MARK: Pipeline

    /// Save the current session's accumulated time into today's history, then
    /// zero the live counters so they can't be double-counted.
    func flushSessionToHistory() {
        let total = goodSeconds + badSeconds
        guard total >= 5 else { return }   // ignore trivial/aborted sessions
        history.record(good: goodSeconds, bad: badSeconds, slouches: slouchEvents, on: Date())
        goodSeconds = 0
        badSeconds = 0
        slouchEvents = 0
    }

    private func resetSession() {
        goodSeconds = 0
        badSeconds = 0
        slouchEvents = 0
        recentSamples = []
        sampleIndex = 0
        lastSampleTime = nil
        lastChartTime = nil
        sessionStartTime = nil
        previousState = .unknown
    }

    private func handle(pitch: Double) {
        let now = Date()
        livePitch = pitch
        guard isMonitoring else { return }

        let state = analyzer.update(pitchDegrees: pitch, now: now)
        postureState = state
        deviation = analyzer.drop

        if isCalibrated {
            // Time spent in good vs bad posture (ignore large gaps / stalls).
            if let last = lastSampleTime {
                let dt = now.timeIntervalSince(last)
                if dt > 0, dt < 2 {
                    if state == .bad { badSeconds += dt }
                    else if state == .good { goodSeconds += dt }
                }
            }
            lastSampleTime = now

            if state == .bad, previousState != .bad { slouchEvents += 1 }

            // Downsample the chart to ~5 Hz to keep it light.
            let chartDue = lastChartTime.map { now.timeIntervalSince($0) >= 0.2 } ?? true
            if chartDue {
                if sessionStartTime == nil { sessionStartTime = now }
                let t = now.timeIntervalSince(sessionStartTime ?? now)
                sampleIndex += 1
                recentSamples.append(DeviationSample(id: sampleIndex, t: t, drop: max(0, deviation)))
                // Keep only the trailing time window so the chart scrolls cleanly.
                let cutoff = t - chartWindowSeconds
                while let first = recentSamples.first, first.t < cutoff {
                    recentSamples.removeFirst()
                }
                lastChartTime = now
            }
        }
        previousState = state

        if state == .bad {
            // The glow scales with how far the head has moved past the chosen
            // threshold. It never captures clicks or covers the screen centre.
            let overshoot = max(0, deviation - threshold)
            overlay.show(intensity: min(1, 0.45 + overshoot / 18))
            alerts.triggerSlouchAlert(
                deviation: deviation,
                sustainedFor: analyzer.slouchDuration,
                now: now
            )
        } else {
            overlay.hide()
        }
    }

    private func updateFocusTimer(now: Date) {
        guard isMonitoring, let focusEndDate else { return }
        let remaining = focusEndDate.timeIntervalSince(now)
        if remaining <= 0 {
            stopMonitoring()
        } else {
            sessionRemainingSeconds = remaining
        }
    }

    // MARK: Derived UI helpers

    var connectionText: String {
        if motion.hasData { return "AirPods connected" }
        if audio.headphonesConnected {
            return audio.deviceName.isEmpty ? "Headphones connected" : "\(audio.deviceName) connected"
        }
        if !motion.isAvailable { return "Headphone motion unavailable" }
        return isMonitoring ? "Waiting for AirPods…" : "No AirPods detected"
    }

    var isConnected: Bool {
        motion.hasData || audio.headphonesConnected
    }

    var statusHeadline: String {
        if let err = motion.lastError { return err }
        if !isMonitoring { return "Paused" }
        if !isCalibrated { return "Sit upright, then Calibrate" }
        switch postureState {
        case .good:    return "Good posture"
        case .bad:     return "Slouching — straighten up"
        case .unknown: return "Reading…"
        }
    }

    /// 0…1 progress of how close the current drop is to the alert threshold.
    var slouchFraction: Double {
        guard threshold > 0 else { return 0 }
        return min(1, max(0, deviation / threshold))
    }

    /// Fixed-width, sliding time window for the live chart's x-axis. Anchored at
    /// 0 until the window fills, then it slides so the latest sample is at the
    /// right edge and old points scroll off the left.
    var chartXDomain: ClosedRange<Double> {
        let last = recentSamples.last?.t ?? 0
        if last <= chartWindowSeconds { return 0...chartWindowSeconds }
        return (last - chartWindowSeconds)...last
    }

    var goodPosturePercent: Double {
        let total = goodSeconds + badSeconds
        return total > 0 ? (goodSeconds / total) * 100 : 100
    }

    var monitoredTimeString: String {
        let total = Int(goodSeconds + badSeconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var focusTimeString: String? {
        guard let remaining = sessionRemainingSeconds else { return nil }
        let total = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var startButtonTitle: String {
        focusDurationMinutes > 0
            ? "Start \(focusDurationMinutes)-minute focus"
            : "Start monitoring"
    }

    var menuBarSymbol: String {
        guard isMonitoring else { return "figure.seated.side" }
        if !isCalibrated { return "scope" }
        switch postureState {
        case .good:    return "figure.stand"
        case .bad:     return "exclamationmark.triangle.fill"
        case .unknown: return "figure.seated.side"
        }
    }
}
