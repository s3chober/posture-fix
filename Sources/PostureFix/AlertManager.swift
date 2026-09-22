import Foundation
import AppKit
import AVFoundation
import UserNotifications

/// Delivers posture nudges: an in‑ear sound, an optional spoken cue, and a
/// macOS notification. A cooldown prevents alert spam while you're slouching.
final class AlertManager {

    /// macOS system sounds (from /System/Library/Sounds) offered as alert cues.
    static let availableSounds = [
        "Funk", "Glass", "Ping", "Submarine", "Hero",
        "Tink", "Sosumi", "Pop", "Purr", "Bottle", "Blow"
    ]

    var soundEnabled = false
    var voiceEnabled = false
    var notificationEnabled = false
    var cooldown: TimeInterval = 180
    /// Total time the user's head must remain below the threshold before an
    /// interruptive cue is allowed. The visual glow appears first.
    var escalationSeconds: TimeInterval = 30
    var soundName = "Tink" {
        didSet { reloadSound() }
    }

    private var lastAlert: Date?
    private let synth = AVSpeechSynthesizer()
    private var sound = NSSound(named: "Tink")

    private func reloadSound() {
        sound = NSSound(named: NSSound.Name(soundName)) ?? NSSound(named: "Tink")
    }

    /// Play the currently selected alert sound once (for previewing in settings).
    func previewSound() {
        sound?.stop()
        sound?.play()
    }

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Reset the cooldown so the next bad-posture event alerts immediately
    /// (e.g. right after calibration).
    func resetCooldown() {
        lastAlert = nil
    }

    func triggerSlouchAlert(
        deviation: Double,
        sustainedFor: TimeInterval,
        now: Date = Date()
    ) {
        guard soundEnabled || voiceEnabled || notificationEnabled else { return }
        guard sustainedFor >= escalationSeconds else { return }
        if let lastAlert, now.timeIntervalSince(lastAlert) < cooldown { return }
        lastAlert = now

        if soundEnabled {
            sound?.stop()
            sound?.play()
        }
        if voiceEnabled {
            let utterance = AVSpeechUtterance(string: "Gently lift your head")
            utterance.rate = 0.5
            synth.speak(utterance)
        }
        if notificationEnabled {
            postNotification(deviation: deviation)
        }
    }

    private func postNotification(deviation: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Posture check"
        content.body = String(
            format: "Your head has been tilted %.0f° below your baseline. Reset if that feels comfortable.",
            abs(deviation)
        )
        content.sound = nil   // we play our own cue
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
