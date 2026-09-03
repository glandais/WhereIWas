import Foundation
import Testing
@testable import WhereIWas

@Suite("ActivityMapping")
struct ActivityMappingTests {
    @Test func dominantKindPrefersMostMoving() {
        #expect(ActivityMapping.dominantKind(stationary: true, walking: false, running: false, cycling: false, automotive: true) == .automotive)
        #expect(ActivityMapping.dominantKind(stationary: false, walking: true, running: true, cycling: false, automotive: false) == .running)
        #expect(ActivityMapping.dominantKind(stationary: false, walking: true, running: false, cycling: true, automotive: false) == .cycling)
        #expect(ActivityMapping.dominantKind(stationary: false, walking: true, running: false, cycling: false, automotive: false) == .walking)
        #expect(ActivityMapping.dominantKind(stationary: true, walking: false, running: false, cycling: false, automotive: false) == .stationary)
        #expect(ActivityMapping.dominantKind(stationary: false, walking: false, running: false, cycling: false, automotive: false) == .unknown)
    }

    @Test func confidenceMappingClamps() {
        #expect(ActivityMapping.confidence(rawValue: 0) == .low)
        #expect(ActivityMapping.confidence(rawValue: 1) == .medium)
        #expect(ActivityMapping.confidence(rawValue: 2) == .high)
        #expect(ActivityMapping.confidence(rawValue: 9) == .high)
        #expect(ActivityMapping.confidence(rawValue: -1) == .low)
    }
}

@Suite("ActivityDebouncer")
struct ActivityDebouncerTests {
    @Test func firstReportAlwaysEmits() {
        var d = ActivityDebouncer(repeatInterval: 30)
        let r1 = d.shouldEmit(kind: .stationary, confidence: .high, at: Date(timeIntervalSince1970: 0))
        #expect(r1)
    }

    @Test func identicalReportIsSuppressedUntilInterval() {
        var d = ActivityDebouncer(repeatInterval: 30)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let r2 = d.shouldEmit(kind: .walking, confidence: .high, at: t0)
        #expect(r2)
        let r3 = d.shouldEmit(kind: .walking, confidence: .high, at: t0.addingTimeInterval(5))
        #expect(!r3)
        let r4 = d.shouldEmit(kind: .walking, confidence: .high, at: t0.addingTimeInterval(29))
        #expect(!r4)
        let r5 = d.shouldEmit(kind: .walking, confidence: .high, at: t0.addingTimeInterval(30))
        #expect(r5)
        let r6 = d.shouldEmit(kind: .walking, confidence: .high, at: t0.addingTimeInterval(31))
        #expect(!r6)
    }

    @Test func changeInKindOrConfidenceEmitsImmediately() {
        var d = ActivityDebouncer(repeatInterval: 30)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let r7 = d.shouldEmit(kind: .walking, confidence: .high, at: t0)
        #expect(r7)
        let r8 = d.shouldEmit(kind: .walking, confidence: .low, at: t0.addingTimeInterval(1))
        #expect(r8)
        let r9 = d.shouldEmit(kind: .stationary, confidence: .low, at: t0.addingTimeInterval(2))
        #expect(r9)
        let r10 = d.shouldEmit(kind: .stationary, confidence: .low, at: t0.addingTimeInterval(3))
        #expect(!r10)
    }

    @Test func resetForgetsHistory() {
        var d = ActivityDebouncer(repeatInterval: 30)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let r11 = d.shouldEmit(kind: .walking, confidence: .high, at: t0)
        #expect(r11)
        d.reset()
        let r12 = d.shouldEmit(kind: .walking, confidence: .high, at: t0.addingTimeInterval(1))
        #expect(r12)
    }
}

@Suite("AccelerometerBurstAnalyzer")
struct AccelerometerBurstAnalyzerTests {
    let analyzer = AccelerometerBurstAnalyzer()

    @Test func restingDeviceIsNotMoving() {
        let samples = (0..<15).map { 1.0 + (Double($0 % 3) - 1) * 0.004 }
        let v = analyzer.analyze(magnitudes: samples)
        #expect(!v.isMoving)
        #expect(v.sampleCount == 15)
        #expect(v.rmsDeviation < 0.01)
    }

    @Test func walkingDeviceIsMoving() {
        let samples = (0..<15).map { 1.0 + 0.3 * sin(Double($0) * 0.9) }
        let v = analyzer.analyze(magnitudes: samples)
        #expect(v.isMoving)
        #expect(v.peakDeviation > 0.2)
    }

    @Test func singlePickupSpikeIsMoving() {
        var samples = Array(repeating: 1.0, count: 14)
        samples.append(1.4)
        let v = analyzer.analyze(magnitudes: samples)
        #expect(v.isMoving)
        #expect(v.peakDeviation == 0.4.rounded(toPlaces: 6) || abs(v.peakDeviation - 0.4) < 1e-9)
    }

    @Test func tooFewSamplesNeverMoving() {
        let v = analyzer.analyze(magnitudes: [1.5, 0.5, 1.6])
        #expect(!v.isMoving)
        #expect(v.sampleCount == 3)
        #expect(analyzer.analyze(magnitudes: []).sampleCount == 0)
    }

    @Test func magnitudeHelper() {
        #expect(abs(AccelerometerBurstAnalyzer.magnitude(x: 0, y: 0, z: -1) - 1) < 1e-12)
        #expect(abs(AccelerometerBurstAnalyzer.magnitude(x: 3, y: 4, z: 0) - 5) < 1e-12)
    }
}

@Suite("SimulatedMotionMonitor")
@MainActor
struct SimulatedMotionMonitorTests {
    @Test func deliversEventsAndTracksLastActivity() {
        let monitor = SimulatedMotionMonitor()
        var received: [MotionEvent] = []
        monitor.start { received.append($0) }
        let ts = Date()
        monitor.simulate(.activity(kind: .cycling, confidence: .high, timestamp: ts))
        #expect(monitor.lastActivity?.kind == .cycling)
        #expect(received == [.activity(kind: .cycling, confidence: .high, timestamp: ts)])
        monitor.setAuthorization(.denied)
        #expect(monitor.authorization == .denied)
        #expect(received.last == .authorizationChanged(.denied))
        monitor.stop()
        monitor.simulate(.steps(count: 3, timestamp: ts))
        #expect(received.count == 2)
        #expect(monitor.calls == ["start", "stop"])
    }

    @Test func burstRequestAnswersWithCannedVerdict() {
        let monitor = SimulatedMotionMonitor()
        monitor.burstVerdict = (true, 0.3)
        var moving: Bool?
        monitor.start { if case .accelerometerBurst(let m, _, _) = $0 { moving = m } }
        monitor.requestAccelerometerBurst(duration: 3)
        #expect(moving == true)
        #expect(monitor.calls.last == "burst(3.0)")
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}
