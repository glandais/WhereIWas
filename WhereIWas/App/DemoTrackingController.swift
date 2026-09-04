#if SCREENSHOTS
import Foundation
import Observation

/// The ``TrackingControlling`` the app runs on in screenshot mode.
///
/// Same idea as `PreviewTrackingController`, but the dataset is built for the
/// App Store rather than for a Xcode canvas: three days of a deployment,
/// resampled from the street geometry of ``DemoTracks`` — a walking loop, a
/// drive across town and a walk at the far end, in the city that matches the
/// launch language.
///
/// Two clocks, on purpose:
///
/// * Status, the transitions list and the audit trail are anchored on
///   ``ScreenshotMode/clock``, so "11 s ago" is true whenever the capture runs;
/// * the map and the export sit on **fixed daytime windows on past days**
///   (yesterday 08:12→10:05, the day before 14:20→16:40), so a capture at 01:45
///   shows the same complete day as one at noon. Only today's drive, the one
///   Status reports on, is tied to the capture instant.
///
/// ``ScreenshotMode/scenario`` picks which story Status tells: `moving` (still
/// driving, fix seconds old) or `stationary` (parked, coarse profile, no
/// session open) — the two Status cards make opposite arguments and cannot
/// share a dataset.
///
/// Everything is fictional: the tracks run between public places over public
/// roads, and nothing in them is anybody's address.
@MainActor
@Observable
final class DemoTrackingController: TrackingControlling {
    var status: TrackingStatus
    var settings: TrackingSettings

    private let storedSamples: [StoredLocationSample]
    private let storedSessions: [TrackingSessionSummary]
    private let transitions: [StateTransitionRecord]
    private let auditEvents: [AuditEvent]

    init() {
        let clock = ScreenshotMode.clock
        let scenario = ScreenshotMode.scenario

        var settings = TrackingSettings()
        // The audit trail is opt-in and off by default; the screenshot that
        // shows it is the one no competitor has, so turn it on.
        settings.auditEnabled = true
        self.settings = settings

        let legs = Self.legs(of: DemoTracks.track(for: ScreenshotMode.languageCode).segments)
        // The afternoon two days ago: the loop and the drive, no arrival walk.
        let dayBefore = Self.place(Array(legs.prefix(2)),
                                   filling: Self.window(dayOffset: -2, from: (14, 20), to: (16, 40),
                                                        clock: clock),
                                   firstSequence: 1,
                                   battery: (0.91, 0.63))
        // Yesterday morning: the whole run, which is the day the map opens on.
        let yesterday = Self.place(legs,
                                   filling: Self.window(dayOffset: -1, from: (8, 12), to: (10, 5),
                                                        clock: clock),
                                   firstSequence: dayBefore.nextSequence,
                                   battery: (0.97, 0.68))
        // Today: the drive only, ending just before "now" when we are still in
        // it, eight minutes ago when we have parked.
        let lastFixAge: TimeInterval = scenario == .moving ? 11 : 8 * 60
        let today = Self.inProgress(legs.count > 1 ? [legs[1]] : legs,
                                    endingAt: clock.addingTimeInterval(-lastFixAge),
                                    firstSequence: yesterday.nextSequence,
                                    battery: scenario == .moving ? (0.88, 0.71) : (0.94, 0.86),
                                    leaveOpen: scenario == .moving)

        storedSamples = dayBefore.samples + yesterday.samples + today.samples
        storedSessions = (dayBefore.sessions + yesterday.sessions + today.sessions)
            .sorted { $0.startedAt > $1.startedAt }

        // The reasons are the machine vocabulary `Formatting.transitionReason`
        // knows how to translate, so this section reads in every locale.
        transitions = Self.transitions(scenario: scenario, today: today, yesterday: yesterday)
        auditEvents = Self.auditTrail(scenario: scenario, drive: today.samples,
                                      transitions: transitions)

        let lastFix = today.samples.last?.fix
        let driving = GPSProfile.profile(for: .automotive, speed: 16, settings: settings)
        let battery = scenario == .moving ? 0.71 : 0.86
        status = TrackingStatus(
            isEnabled: true,
            phase: scenario == .moving ? .moving : .stationary,
            // Parked, the engine holds no high-accuracy profile at all; what
            // CoreLocation is still running is the near-free coarse one, which
            // is why the screen reads "Stationary (coarse)" and not "GPS off".
            activeProfile: scenario == .moving ? driving : nil,
            appliedProfile: scenario == .moving ? driving : .stationaryCoarse,
            lastActivity: scenario == .moving ? .automotive : .stationary,
            lastActivityConfidence: .high,
            lastFix: lastFix,
            lastFixSource: .gps,
            acceptedCount: storedSamples.count,
            rejectedCount: 11,
            // Three days are on screen; the store holds a month of them.
            stats: StoreStats(totalSamples: 21_734,
                              pendingUpload: 0,
                              oldestSample: clock.addingTimeInterval(-29 * 86_400),
                              newestSample: lastFix?.timestamp,
                              sessionCount: storedSessions.count),
            // The simulator reports -1 for the battery, so the whole status is
            // supplied as a value rather than read from a real coordinator.
            batteryLevel: battery,
            batteryState: .unplugged,
            locationAuthorization: .always,
            hasFullAccuracy: true,
            motionAuthorization: .authorized,
            currentSessionID: scenario == .moving ? today.sessions.last?.id : nil,
            lastTransition: transitions.first,
            lastError: nil
        )
    }

    // MARK: Track

    private typealias Coordinate = (latitude: Double, longitude: Double)

    /// One resampled leg: fixes placed along the polyline at offsets from the
    /// leg's own start, with no wall-clock time yet — the day decides that.
    private struct RawFix {
        let offset: TimeInterval
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let speed: Double
        let course: Double
    }

    private struct Leg {
        let mode: DemoTrackSegment.Mode
        let fixes: [RawFix]
    }

    /// One day of the dataset: its samples, and one session per leg.
    private struct DemoDay {
        var samples: [StoredLocationSample]
        var sessions: [TrackingSessionSummary]

        var nextSequence: Int64 { (samples.last?.sequence ?? 0) + 1 }
    }

    private static func legs(of segments: [DemoTrackSegment]) -> [Leg] {
        segments.map { Leg(mode: $0.mode, fixes: resample($0)) }
    }

    /// Walks the polyline at the speed the mode implies, emitting a fix every
    /// `step` seconds — the way CoreLocation delivers them — plus the
    /// destination itself, so the drawn track ends where the street does.
    private static func resample(_ segment: DemoTrackSegment) -> [RawFix] {
        let coordinates = segment.coordinates
        guard coordinates.count > 1 else { return [] }

        var cumulative: [Double] = [0]
        for i in 1..<coordinates.count {
            cumulative.append(cumulative[i - 1] + meters(coordinates[i - 1], coordinates[i]))
        }
        guard let length = cumulative.last, length > 0 else { return [] }

        func fix(at travelled: Double, offset: TimeInterval, vertex: Int) -> RawFix {
            let from = coordinates[vertex - 1]
            let to = coordinates[vertex]
            let span = cumulative[vertex] - cumulative[vertex - 1]
            let f = span > 0 ? min(1, max(0, (travelled - cumulative[vertex - 1]) / span)) : 0
            let progress = travelled / length
            return RawFix(offset: offset,
                          latitude: from.latitude + (to.latitude - from.latitude) * f,
                          longitude: from.longitude + (to.longitude - from.longitude) * f,
                          // No city elevation model here: a plausible relief,
                          // not the real one. Exports carry it as metadata.
                          altitude: 42 + 9 * sin(progress * 3 * .pi),
                          // Accuracy wanders the way it does between streets
                          // and open squares, better on foot than at speed.
                          horizontalAccuracy: segment.mode == .walking
                              ? 4.2 + 2.6 * abs(sin(progress * 11))
                              : 6 + 4 * abs(sin(progress * 7)),
                          speed: speed(mode: segment.mode, at: progress),
                          course: bearing(from, to))
        }

        let step: TimeInterval = segment.mode == .walking ? 8 : 5
        var fixes: [RawFix] = []
        var travelled = 0.0
        var offset = 0.0
        var vertex = 1
        while true {
            while vertex < coordinates.count - 1, cumulative[vertex] < travelled { vertex += 1 }
            let sample = fix(at: travelled, offset: offset, vertex: vertex)
            fixes.append(sample)
            if travelled >= length { break }
            let advance = sample.speed * step
            if travelled + advance >= length {
                offset += (length - travelled) / max(sample.speed, 0.5)
                travelled = length
            } else {
                travelled += advance
                offset += step
            }
        }
        return fixes
    }

    /// Shapes how today's leg ends, which is the fix the Status card reads.
    ///
    /// The resampler always coasts into the destination, and its speed floor —
    /// there so the walk terminates rather than crawling the last metre in
    /// hundreds of fixes — leaves the final fix at a few km/h. That is wrong
    /// twice over: a drive *still under way* has not arrived at all, and a
    /// *parked* one is not doing 9 km/h. So the open session keeps only the
    /// part before the slow-in, and the closed one comes to a stop.
    private static func shapeEnding(_ leg: Leg, arrived: Bool) -> Leg {
        guard leg.fixes.count > 2 else { return leg }
        if arrived {
            guard let last = leg.fixes.last else { return leg }
            return Leg(mode: leg.mode, fixes: leg.fixes.dropLast() + [
                RawFix(offset: last.offset, latitude: last.latitude, longitude: last.longitude,
                       altitude: last.altitude, horizontalAccuracy: last.horizontalAccuracy,
                       speed: 0, course: last.course)
            ])
        }
        let underway = Int((Double(leg.fixes.count) * 0.65).rounded())
        return Leg(mode: leg.mode, fixes: Array(leg.fixes.prefix(max(2, underway))))
    }

    /// Speed in m/s at `progress` along a leg.
    private static func speed(mode: DemoTrackSegment.Mode, at progress: Double) -> Double {
        switch mode {
        case .walking:
            return 1.35 + 0.18 * sin(progress * 9 * .pi)
        case .automotive:
            // Pulls away from the kerb, cruises, slows into the destination,
            // with a ripple for the lights in between.
            return max(2.5, 4 + 11 * sin(progress * .pi) + 1.6 * sin(progress * 17))
        }
    }

    // MARK: Days

    /// The fixed daytime window a past day is laid out in. Local time, because
    /// that is the clock the map's day picker and the session list read.
    private static func window(dayOffset: Int, from: (hour: Int, minute: Int),
                               to: (hour: Int, minute: Int), clock: Date) -> DateInterval {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset,
                                to: calendar.startOfDay(for: clock)) ?? clock
        let start = calendar.date(bySettingHour: from.hour, minute: from.minute, second: 0, of: day) ?? day
        let end = calendar.date(bySettingHour: to.hour, minute: to.minute, second: 0, of: day) ?? day
        return DateInterval(start: start, end: max(end, start))
    }

    /// Lays the legs inside `window`: they are walked at their own speed, and
    /// what is left of the window is the time spent at each stop — capped, so
    /// a day with a single stop does not turn it into a two-hour wait.
    private static func place(_ legs: [Leg], filling window: DateInterval,
                              firstSequence: Int64, battery: (Double, Double)) -> DemoDay {
        let moving = legs.reduce(0) { $0 + ($1.fixes.last?.offset ?? 0) }
        let stops = Double(max(1, legs.count - 1))
        let pause = min(45 * 60, max(180, (window.duration - moving) / stops))
        return place(legs, startingAt: window.start, pause: pause, timeScale: 1,
                     firstSequence: firstSequence, battery: battery, leaveOpen: false)
    }

    /// Today's leg, laid so its last sample lands on `end`.
    ///
    /// Captures run at any hour, so a run just after midnight gets the same
    /// drive compressed into what there is of the day rather than one that
    /// started yesterday — the map and the Status counters both read "today".
    private static func inProgress(_ legs: [Leg], endingAt end: Date, firstSequence: Int64,
                                   battery: (Double, Double), leaveOpen: Bool) -> DemoDay {
        let legs = legs.map { shapeEnding($0, arrived: !leaveOpen) }
        let duration = legs.reduce(0) { $0 + ($1.fixes.last?.offset ?? 0) }
        let available = end.timeIntervalSince(Calendar.current.startOfDay(for: end)) - 300
        let scale = duration > 0 ? min(1, max(0.02, available / duration)) : 1
        return place(legs, startingAt: end.addingTimeInterval(-duration * scale), pause: 0,
                     timeScale: scale, firstSequence: firstSequence,
                     battery: battery, leaveOpen: leaveOpen)
    }

    private static func place(_ legs: [Leg], startingAt start: Date, pause: TimeInterval,
                              timeScale: Double, firstSequence: Int64,
                              battery: (Double, Double), leaveOpen: Bool) -> DemoDay {
        let total = legs.reduce(0) { $0 + $1.fixes.count }
        var samples: [StoredLocationSample] = []
        var sessions: [TrackingSessionSummary] = []
        var sequence = firstSequence
        var legStart = start

        for (index, leg) in legs.enumerated() {
            let sessionID = UUID()
            let firstIndex = samples.count
            for raw in leg.fixes {
                // The battery drains over the whole day, not over each leg.
                let progress = total > 1 ? Double(samples.count) / Double(total - 1) : 0
                let level = battery.0 + (battery.1 - battery.0) * progress
                let fix = LocationFix(latitude: raw.latitude,
                                      longitude: raw.longitude,
                                      altitude: raw.altitude,
                                      horizontalAccuracy: raw.horizontalAccuracy,
                                      verticalAccuracy: raw.horizontalAccuracy * 1.7,
                                      speed: raw.speed,
                                      speedAccuracy: leg.mode == .walking ? 0.4 : 0.9,
                                      course: raw.course,
                                      timestamp: legStart.addingTimeInterval(raw.offset * timeScale))
                let annotation = SampleAnnotation(activity: leg.mode == .walking ? .walking : .automotive,
                                                  activityConfidence: .high,
                                                  phase: .moving,
                                                  batteryLevel: (level * 100).rounded() / 100,
                                                  batteryState: .unplugged,
                                                  sessionID: sessionID,
                                                  // The label of the profile the
                                                  // engine really runs, so the
                                                  // exports read like real ones.
                                                  profileLabel: leg.mode == .walking ? "walking" : "automotive")
                samples.append(StoredLocationSample(sequence: sequence, fix: fix, annotation: annotation,
                                                    source: .gps, uploaded: false, createdAt: fix.timestamp))
                sequence += 1
            }
            let legSamples = Array(samples[firstIndex...])
            sessions.append(summary(id: sessionID, samples: legSamples,
                                    open: leaveOpen && index == legs.count - 1))
            legStart = (legSamples.last?.fix.timestamp ?? legStart).addingTimeInterval(pause)
        }
        return DemoDay(samples: samples, sessions: sessions)
    }

    /// Session summaries are *derived*: the count and the distance are what the
    /// samples say, so the export list can never contradict the map.
    private static func summary(id: UUID, samples: [StoredLocationSample], open: Bool) -> TrackingSessionSummary {
        let distance = zip(samples, samples.dropFirst()).reduce(0) { $0 + $1.0.fix.distance(to: $1.1.fix) }
        return TrackingSessionSummary(id: id,
                                      startedAt: samples.first?.fix.timestamp ?? .now,
                                      endedAt: open ? nil : samples.last?.fix.timestamp,
                                      sampleCount: samples.count,
                                      distanceMeters: distance)
    }

    // MARK: Geometry

    /// Great-circle distance in meters. `LocationFix.distance(to:)` is the same
    /// haversine, but the fixture geometry has neither a timestamp nor an
    /// accuracy to build a fix from yet.
    private static func meters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north — what
    /// CoreLocation reports as `course`.
    private static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: Transitions

    /// Newest first, and telling the same story as the scenario: parked, the
    /// list opens on the stillness timer that turned GPS off.
    private static func transitions(scenario: ScreenshotScenario,
                                    today: DemoDay, yesterday: DemoDay) -> [StateTransitionRecord] {
        var records: [StateTransitionRecord] = []
        if scenario == .stationary, let parked = today.samples.last?.fix.timestamp {
            records.append(StateTransitionRecord(timestamp: parked.addingTimeInterval(90),
                                                 from: .moving, to: .stationary,
                                                 reason: "stillnessTimerFired", batteryLevel: 0.86))
        }
        if let departure = today.samples.first?.fix.timestamp {
            records.append(StateTransitionRecord(timestamp: departure.addingTimeInterval(-8),
                                                 from: .probing, to: .moving,
                                                 reason: "motionActivity(automotive, high)",
                                                 batteryLevel: 0.88))
            records.append(StateTransitionRecord(timestamp: departure.addingTimeInterval(-70),
                                                 from: .stationary, to: .probing,
                                                 reason: "significantChange", batteryLevel: 0.88))
        }
        if let last = yesterday.samples.last?.fix.timestamp {
            records.append(StateTransitionRecord(timestamp: last.addingTimeInterval(120),
                                                 from: .moving, to: .stationary,
                                                 reason: "stillnessTimerFired", batteryLevel: 0.68))
        }
        if let first = yesterday.samples.first?.fix.timestamp {
            records.append(StateTransitionRecord(timestamp: first.addingTimeInterval(-15),
                                                 from: .probing, to: .moving,
                                                 reason: "motionActivity(walking, high)",
                                                 batteryLevel: 0.97))
            records.append(StateTransitionRecord(timestamp: first.addingTimeInterval(-95),
                                                 from: .disabled, to: .probing,
                                                 reason: "enable", batteryLevel: 0.97))
        }
        return records
    }

    // MARK: Audit trail

    /// Enough events to fill the screen with several categories and
    /// severities, and to show the per-fix validation checks — the part of the
    /// trail worth putting on the store page. No `store.insert` batches: they
    /// are the one high-volume line that says nothing to a reader.
    ///
    /// Coordinates and battery levels are read off the samples they describe,
    /// so the trail agrees with the map and the export.
    private static func auditTrail(scenario: ScreenshotScenario,
                                   drive: [StoredLocationSample],
                                   transitions: [StateTransitionRecord]) -> [AuditEvent] {
        guard let last = drive.last else { return [] }
        let previous = drive.dropLast(3).last ?? last
        let departure = drive.first?.fix.timestamp ?? last.fix.timestamp
        let battery = last.annotation.batteryLevel

        var events: [AuditEvent] = []

        // Parked, the newest events are the ones that turned GPS down; still
        // driving, they are the fixes themselves.
        if scenario == .stationary {
            let parked = last.fix.timestamp.addingTimeInterval(90)
            events.append(AuditEvent(timestamp: parked.addingTimeInterval(2),
                                     category: .effect, severity: .info,
                                     name: "gps.profile",
                                     message: "GPS reconfigured for stationary-coarse",
                                     details: [AuditDetail("profile", "stationary-coarse"),
                                               AuditDetail("desiredAccuracy", "threeKilometers"),
                                               AuditDetail("distanceFilter", 3_000.0),
                                               AuditDetail("activityType", "other")],
                                     phase: .stationary, batteryLevel: battery))
            events.append(AuditEvent(timestamp: parked,
                                     category: .state, severity: .info,
                                     name: "state.transition",
                                     message: "moving → stationary",
                                     details: [AuditDetail("from", "moving"), AuditDetail("to", "stationary"),
                                               AuditDetail("input", "stillness timer"),
                                               AuditDetail("reason", "stillnessTimerFired")],
                                     phase: .stationary, batteryLevel: battery))
        }

        events.append(AuditEvent(timestamp: last.fix.timestamp,
                                 category: .location, severity: .debug,
                                 name: "fix.accepted",
                                 message: "Fix accepted",
                                 details: [AuditDetail("latitude", last.fix.latitude, decimals: 6),
                                           AuditDetail("longitude", last.fix.longitude, decimals: 6),
                                           AuditDetail("horizontalAccuracy", last.fix.horizontalAccuracy),
                                           AuditDetail("speed", last.fix.speed),
                                           AuditDetail("profile", "automotive"),
                                           AuditDetail("check.horizontalAccuracy.valid",
                                                       "passed (\(fmt(last.fix.horizontalAccuracy)) vs > 0 m)"),
                                           AuditDetail("check.horizontalAccuracy.withinLimit",
                                                       "passed (\(fmt(last.fix.horizontalAccuracy)) vs <= 50.00 m)"),
                                           AuditDetail("check.timestamp.notInFuture", "passed"),
                                           AuditDetail("check.timestamp.notStale", "passed (0.24 s vs <= 30.00 s)"),
                                           AuditDetail("check.distance.notDuplicate",
                                                       "passed (\(fmt(previous.fix.distance(to: last.fix))) vs > 0.00 m)")],
                                 phase: .moving, batteryLevel: battery))

        // The card the audit trail sells: a fix the filter threw away, with the
        // reason and every check it ran.
        events.append(AuditEvent(timestamp: last.fix.timestamp.addingTimeInterval(-6),
                                 category: .filter, severity: .info,
                                 name: "fix.rejected",
                                 message: "Fix rejected: poorAccuracy(94.0 m)",
                                 details: [AuditDetail("latitude", previous.fix.latitude, decimals: 6),
                                           AuditDetail("longitude", previous.fix.longitude, decimals: 6),
                                           AuditDetail("horizontalAccuracy", 94.0),
                                           AuditDetail("rejection", "poorAccuracy(94.0 m)"),
                                           AuditDetail("check.horizontalAccuracy.valid", "passed (94.00 vs > 0 m)"),
                                           AuditDetail("check.horizontalAccuracy.withinLimit",
                                                       "failed (94.00 vs <= 50.00 m)"),
                                           AuditDetail("check.timestamp.notStale", "skipped")],
                                 phase: .moving, batteryLevel: battery))

        events.append(AuditEvent(timestamp: departure.addingTimeInterval(-6),
                                 category: .effect, severity: .info,
                                 name: "gps.profile",
                                 message: "GPS reconfigured for automotive",
                                 details: [AuditDetail("profile", "automotive"),
                                           AuditDetail("desiredAccuracy", "bestForNavigation"),
                                           AuditDetail("distanceFilter", 50.0),
                                           AuditDetail("activityType", "automotiveNavigation")],
                                 phase: .moving, batteryLevel: 0.88))
        events.append(AuditEvent(timestamp: departure.addingTimeInterval(-8),
                                 category: .state, severity: .info,
                                 name: "state.transition",
                                 message: "probing → moving",
                                 details: [AuditDetail("from", "probing"), AuditDetail("to", "moving"),
                                           AuditDetail("input", "activity automotive/high"),
                                           AuditDetail("reason", "motionActivity")],
                                 phase: .moving, batteryLevel: 0.88))
        events.append(AuditEvent(timestamp: departure.addingTimeInterval(-12),
                                 category: .motion, severity: .debug,
                                 name: "motion.event",
                                 message: "Activity automotive (high confidence)",
                                 details: [AuditDetail("kind", "automotive"), AuditDetail("confidence", "high")],
                                 phase: .probing, batteryLevel: 0.88))
        events.append(AuditEvent(timestamp: departure.addingTimeInterval(-70),
                                 category: .location, severity: .info,
                                 name: "significantChange",
                                 message: "Significant location change received",
                                 details: [AuditDetail("latitude", drive.first?.fix.latitude ?? 0, decimals: 6),
                                           AuditDetail("longitude", drive.first?.fix.longitude ?? 0, decimals: 6),
                                           AuditDetail("horizontalAccuracy", 65.0)],
                                 phase: .stationary, batteryLevel: 0.88))

        // The oldest two are anchored on the enable that opened yesterday.
        if let armed = transitions.last?.timestamp {
            events.append(AuditEvent(timestamp: armed.addingTimeInterval(6),
                                     category: .permission, severity: .info,
                                     name: "permission.location",
                                     message: "Location authorization: always",
                                     details: [AuditDetail("status", "always"),
                                               AuditDetail("fullAccuracy", true)],
                                     phase: .probing, batteryLevel: 0.97))
            events.append(AuditEvent(timestamp: armed,
                                     category: .lifecycle, severity: .info,
                                     name: "app.bootstrap",
                                     message: "Tracking re-armed at launch",
                                     details: [AuditDetail("launchedForLocation", true),
                                               AuditDetail("trackingEnabled", true)],
                                     phase: .disabled, batteryLevel: 0.97))
        }
        return events
    }

    /// Two decimals, locale-independent: audit payloads are machine text.
    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", locale: nil, value)
    }

    // MARK: TrackingControlling

    func setTrackingEnabled(_ enabled: Bool) {
        status.isEnabled = enabled
        status.phase = enabled ? .moving : .disabled
        status.activeProfile = enabled ? GPSProfile.profile(for: .automotive, speed: 16, settings: settings) : nil
        status.appliedProfile = status.activeProfile
    }

    func requestPermissions() {}

    func samples(in interval: DateInterval) async throws -> [StoredLocationSample] {
        storedSamples.filter { interval.contains($0.fix.timestamp) }
    }

    func samples(sessionID: UUID) async throws -> [StoredLocationSample] {
        storedSamples.filter { $0.annotation.sessionID == sessionID }
    }

    func sessions() async throws -> [TrackingSessionSummary] { storedSessions }

    func recentTransitions(limit: Int) async throws -> [StateTransitionRecord] {
        Array(transitions.prefix(limit))
    }

    /// Runs the real exporters, so the Export screen shows a believable file
    /// size instead of a few bytes. The names are short on purpose: the card
    /// shows the file name, and a sentence there reads like a settings row.
    func export(format: ExportFormat, sessionID: UUID?, interval: DateInterval?) async throws -> URL {
        let samples: [StoredLocationSample]
        let name: String
        if let sessionID {
            samples = try await self.samples(sessionID: sessionID)
            name = "WhereIWas-session"
        } else if let interval {
            samples = try await self.samples(in: interval)
            name = "WhereIWas-range"
        } else {
            samples = storedSamples
            name = "WhereIWas-history"
        }
        switch format {
        case .gpx:
            return try GPXExporter.write(samples, name: name)
        case .json:
            return try JSONExporter.write(samples, name: name)
        }
    }

    func purgeNow() async throws -> Int { 0 }

    func auditEvents(matching query: AuditQuery) async throws -> [AuditEvent] {
        guard settings.auditEnabled else { return [] }
        var events = auditEvents.filter(query.matches)
        if query.limit > 0, events.count > query.limit {
            events = Array(events.prefix(query.limit))
        }
        return events
    }

    func auditCount() async throws -> Int { settings.auditEnabled ? 1_284 : 0 }

    func exportAudit(format: AuditExportFormat, query: AuditQuery) async throws -> URL {
        try AuditExporter.write(auditEvents.filter(query.matches), settings: settings, format: format)
    }

    func clearAudit() async -> Int { 0 }
}
#endif
