import Foundation
import Darwin

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

@main
struct PostureAnalyzerTestRunner {
    static func main() {
        requiresCalibration()
        sustainedDropTriggersBadPosture()
        briefDropDoesNotTrigger()
        recoveryUsesHysteresis()
        invertHandlesOppositePitchDirection()

        if failures.isEmpty {
            print("✓ 5 posture analyzer tests passed")
        } else {
            failures.forEach { print("✗ \($0)") }
            exit(1)
        }
    }

    private static func requiresCalibration() {
        let analyzer = PostureAnalyzer(smoothingFactor: 1)
        expect(analyzer.update(pitchDegrees: 10) == .unknown, "uncalibrated motion should be unknown")
        expect(!analyzer.isCalibrated, "analyzer should begin uncalibrated")
    }

    private static func sustainedDropTriggersBadPosture() {
        let analyzer = PostureAnalyzer(smoothingFactor: 1)
        analyzer.thresholdDegrees = 12
        analyzer.holdSeconds = 8

        let start = Date(timeIntervalSince1970: 1_000)
        _ = analyzer.update(pitchDegrees: 20, now: start)
        expect(analyzer.calibrate(), "calibration should succeed after a motion sample")
        expect(analyzer.update(pitchDegrees: 6, now: start.addingTimeInterval(1)) == .good, "drop should not trigger immediately")
        expect(analyzer.update(pitchDegrees: 6, now: start.addingTimeInterval(8.9)) == .good, "drop should respect hold time")
        expect(analyzer.update(pitchDegrees: 6, now: start.addingTimeInterval(9.1)) == .bad, "sustained drop should trigger")
        expect(abs(analyzer.slouchDuration - 8.1) < 0.01, "slouch duration should be tracked")
    }

    private static func briefDropDoesNotTrigger() {
        let analyzer = PostureAnalyzer(smoothingFactor: 1)
        analyzer.thresholdDegrees = 10
        analyzer.holdSeconds = 5

        let start = Date(timeIntervalSince1970: 2_000)
        _ = analyzer.update(pitchDegrees: 0, now: start)
        _ = analyzer.calibrate()
        expect(analyzer.update(pitchDegrees: -15, now: start.addingTimeInterval(1)) == .good, "brief drop should remain good")
        expect(analyzer.update(pitchDegrees: 0, now: start.addingTimeInterval(3)) == .good, "recovery should cancel pending trigger")
        expect(analyzer.slouchDuration == 0, "recovery should reset duration")
    }

    private static func recoveryUsesHysteresis() {
        let analyzer = PostureAnalyzer(smoothingFactor: 1)
        analyzer.thresholdDegrees = 10
        analyzer.holdSeconds = 2
        analyzer.recoverSeconds = 1.5

        let start = Date(timeIntervalSince1970: 3_000)
        _ = analyzer.update(pitchDegrees: 0, now: start)
        _ = analyzer.calibrate()
        _ = analyzer.update(pitchDegrees: -12, now: start.addingTimeInterval(1))
        expect(analyzer.update(pitchDegrees: -12, now: start.addingTimeInterval(3.1)) == .bad, "sustained drop should become bad")
        expect(analyzer.update(pitchDegrees: 0, now: start.addingTimeInterval(4)) == .bad, "recovery should not flicker immediately")
        expect(analyzer.update(pitchDegrees: 0, now: start.addingTimeInterval(5.6)) == .good, "sustained recovery should become good")
    }

    private static func invertHandlesOppositePitchDirection() {
        let analyzer = PostureAnalyzer(smoothingFactor: 1)
        analyzer.thresholdDegrees = 10
        analyzer.holdSeconds = 1
        analyzer.invert = true

        let start = Date(timeIntervalSince1970: 4_000)
        _ = analyzer.update(pitchDegrees: 0, now: start)
        _ = analyzer.calibrate()
        _ = analyzer.update(pitchDegrees: 15, now: start.addingTimeInterval(1))
        expect(analyzer.update(pitchDegrees: 15, now: start.addingTimeInterval(2.1)) == .bad, "reverse direction should trigger when enabled")
    }
}
