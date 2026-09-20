import MapKit
import SwiftUI

/// One day's track. A day bar at the top, the trace coloured by the activity
/// that produced it, the user's live location, and a summary card that either
/// breaks the day down or describes the point tapped.
struct MapView: View {
    @Environment(\.trackingController) private var controller

    #if SCREENSHOTS
    // Today only holds the drive still in progress; the card is about a whole
    // day of a trip, so the shot opens on the last complete one.
    @State private var day: Date = ScreenshotMode.isActive
        ? Calendar.current.date(byAdding: .day, value: -1,
                                to: Calendar.current.startOfDay(for: ScreenshotMode.clock))
            ?? Calendar.current.startOfDay(for: .now)
        : Calendar.current.startOfDay(for: .now)
    #else
    @State private var day: Date = Calendar.current.startOfDay(for: .now)
    #endif
    @State private var samples: [StoredLocationSample] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedSequence: Int64?

    /// Lets `MapUserLocationButton` live in an overlay of our own instead of
    /// `.mapControls`, whose corner the day bar already needs.
    @Namespace private var mapScope

    private var calendar: Calendar { .current }
    private var isToday: Bool { calendar.isDateInToday(day) }

    private var selectedSample: StoredLocationSample? {
        guard let selectedSequence else { return nil }
        return samples.first { $0.sequence == selectedSequence }
    }

    /// The track cut into runs of one activity, so each can be drawn — and
    /// measured — in its own colour.
    private var legs: [TrackLeg] { TrackLeg.split(samples) }

    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selectedSequence, scope: mapScope) {
                UserAnnotation()

                ForEach(legs) { leg in
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(leg.group.color,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }

                if let first = samples.first {
                    Marker("map.marker.start", systemImage: "flag", coordinate: coordinate(of: first))
                        .tint(Theme.Tone.positive.color)
                        .tag(first.sequence)
                }
                if let last = samples.last, samples.count > 1 {
                    Marker("map.marker.end", systemImage: "flag.checkered", coordinate: coordinate(of: last))
                        .tint(Theme.Palette.ink)
                        .tag(last.sequence)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapScaleView(scope: mapScope) }
            .safeAreaInset(edge: .top, spacing: 0) { dayBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
            .overlay { emptyState }
            .navigationBarHidden(true)
            .task(id: day) { await load() }
            .task(id: controller.status.acceptedCount) {
                // Live refresh while looking at today.
                if isToday, !samples.isEmpty || controller.status.acceptedCount > 0 { await load(fit: false) }
            }
        }
        .mapScope(mapScope)
    }

    // MARK: Chrome

    private var dayBar: some View {
        HStack(spacing: Theme.Spacing.row) {
            Button { shift(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(MapControlButtonStyle())
            .accessibilityLabel("map.previousDay")

            DatePicker("map.dayPicker", selection: $day, in: ...Date.now, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.minimumTapTarget)
                .background(Theme.Palette.surface, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                }

            Button { shift(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(MapControlButtonStyle())
            .disabled(isToday)
            .accessibilityLabel("map.nextDay")
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { RowSeparator() }
    }

    /// Controls and summary in one bottom inset.
    ///
    /// The controls used to be a top-trailing overlay, which landed on top of
    /// the day bar: an overlay aligns to the composed view's bounds, and the
    /// bar is part of them. Stacking them here puts them a fixed gap above the
    /// summary card with nothing to collide with.
    private var bottomChrome: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                #if SCREENSHOTS
                // Nothing is locating us in screenshot mode, so the button
                // would spin forever in the corner of every shot.
                if !ScreenshotMode.isActive { MapUserLocationButton(scope: mapScope) }
                #else
                MapUserLocationButton(scope: mapScope)
                #endif
                MapCompass(scope: mapScope)
                Button { fitTrack() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(MapControlButtonStyle())
                .disabled(samples.isEmpty)
                .accessibilityLabel("map.fitTrack")
            }
            .mapControlVisibility(.visible)
            .padding(.trailing, 12)

            summaryCard
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            ProgressView()
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.control))
        } else if samples.isEmpty {
            ContentUnavailableView {
                Label("map.empty.title", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            } description: {
                if let loadError {
                    Text(verbatim: loadError)
                } else {
                    Text(verbatim: String(localized: "map.empty.description",
                                          defaultValue: "No samples recorded on \(Formatting.day(day))."))
                }
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.card))
            .padding(32)
            .allowsHitTesting(false)
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summaryCard: some View {
        if let sample = selectedSample {
            SelectedSampleCard(sample: sample) { selectedSequence = nil }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        } else if !samples.isEmpty {
            dayBreakdownCard
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private var dayBreakdownCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: Theme.Spacing.row) {
                    StatTile(value: Formatting.distance(pathLength), label: "map.stat.distance")
                    StatTile(value: Formatting.count(samples.count), label: "map.stat.points")
                    if let first = samples.first, let last = samples.last {
                        StatTile(value: "\(Formatting.clock(first.fix.timestamp))–\(Formatting.clock(last.fix.timestamp))",
                                 label: "map.stat.span")
                    }
                }

                let breakdown = TrackLeg.breakdown(legs)
                if breakdown.count > 1 {
                    RowSeparator()
                    // The proportions of the day, then the numbers behind
                    // them. Two encodings of the same thing: the bar is read
                    // at a glance, the legend answers "how much exactly".
                    ProportionalHStack(spacing: 3, weights: breakdown.map(\.distance)) {
                        ForEach(breakdown) { part in
                            Capsule()
                                .fill(part.group.color)
                                .frame(height: 7)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("map.breakdown.title")

                    FlowRow(spacing: 12) {
                        ForEach(breakdown) { part in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(part.group.color)
                                    .frame(width: 8, height: 8)
                                Text(verbatim: "\(part.group.title) \(Formatting.distance(part.distance))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Palette.ink)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    // MARK: Logic

    private var pathLength: Double {
        guard samples.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<samples.count {
            total += samples[i].fix.distance(to: samples[i - 1].fix)
        }
        return total
    }

    private func coordinate(of sample: StoredLocationSample) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: sample.fix.latitude, longitude: sample.fix.longitude)
    }

    private func shift(by days: Int) {
        if let next = calendar.date(byAdding: .day, value: days, to: day) {
            day = min(next, calendar.startOfDay(for: .now))
        }
    }

    private func load(fit: Bool = true) async {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        if samples.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            samples = try await controller.samples(in: DateInterval(start: start, end: end))
            loadError = nil
            selectedSequence = nil
            if fit { fitTrack() }
        } catch {
            samples = []
            loadError = error.localizedDescription
        }
    }

    private func fitTrack() {
        let coords = samples.map(coordinate(of:))
        guard !coords.isEmpty else {
            position = .userLocation(fallback: .automatic)
            return
        }
        var rect = MKMapRect.null
        for c in coords {
            let point = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        // Give a single point some size, and pad the rest.
        let padded = rect.insetBy(dx: -max(rect.width * 0.15, 200), dy: -max(rect.height * 0.15, 200))
        withAnimation { position = .rect(padded) }
    }
}

// MARK: - Track legs

/// The activities collapsed into the four that are worth telling apart on a
/// map: walking and running are both "on foot", stationary and unclassified
/// are both "idle".
enum TrackGroup: String, Identifiable, CaseIterable {
    case onFoot, cycling, vehicle, idle

    var id: String { rawValue }

    init(_ activity: ActivityKind) {
        switch activity {
        case .walking, .running: self = .onFoot
        case .cycling: self = .cycling
        case .automotive: self = .vehicle
        case .stationary, .unknown: self = .idle
        }
    }

    var color: Color {
        switch self {
        case .onFoot: return Theme.Track.onFoot
        case .cycling: return Theme.Track.cycling
        case .vehicle: return Theme.Track.vehicle
        case .idle: return Theme.Track.idle
        }
    }

    var title: String {
        switch self {
        case .onFoot: return String(localized: "track.onFoot", defaultValue: "On foot",
                                    comment: "Map legend: walking and running together")
        case .cycling: return String(localized: "activity.cycling", defaultValue: "Cycling")
        case .vehicle: return String(localized: "activity.driving", defaultValue: "Driving")
        case .idle: return String(localized: "track.idle", defaultValue: "Still",
                                  comment: "Map legend: stationary or unclassified stretches")
        }
    }
}

/// A run of consecutive samples sharing one ``TrackGroup``.
struct TrackLeg: Identifiable {
    let id: Int64
    let group: TrackGroup
    let coordinates: [CLLocationCoordinate2D]
    let distance: Double

    /// Cuts a day into legs. Consecutive legs share their boundary sample, or
    /// the polylines would show a gap at every activity change.
    static func split(_ samples: [StoredLocationSample]) -> [TrackLeg] {
        guard samples.count > 1 else { return [] }
        var legs: [TrackLeg] = []
        var current: [StoredLocationSample] = [samples[0]]
        var group = TrackGroup(samples[0].annotation.activity)

        func close() {
            guard current.count > 1 else { return }
            var distance = 0.0
            for i in 1..<current.count {
                distance += current[i].fix.distance(to: current[i - 1].fix)
            }
            legs.append(TrackLeg(id: current[0].sequence,
                                 group: group,
                                 coordinates: current.map {
                                     CLLocationCoordinate2D(latitude: $0.fix.latitude,
                                                            longitude: $0.fix.longitude)
                                 },
                                 distance: distance))
        }

        for sample in samples.dropFirst() {
            let next = TrackGroup(sample.annotation.activity)
            if next == group {
                current.append(sample)
            } else {
                current.append(sample)
                close()
                current = [sample]
                group = next
            }
        }
        close()
        return legs
    }

    /// Distance per group, largest first, dropping groups that contributed
    /// nothing measurable.
    static func breakdown(_ legs: [TrackLeg]) -> [TrackBreakdownPart] {
        var totals: [TrackGroup: Double] = [:]
        for leg in legs { totals[leg.group, default: 0] += leg.distance }
        return totals
            .filter { $0.value >= 1 }
            .map { TrackBreakdownPart(group: $0.key, distance: $0.value) }
            .sorted { $0.distance > $1.distance }
    }
}

struct TrackBreakdownPart: Identifiable {
    let group: TrackGroup
    let distance: Double
    var id: String { group.id }
}

// MARK: - Pieces

/// The card describing the tapped point.
private struct SelectedSampleCard: View {
    let sample: StoredLocationSample
    let onClose: () -> Void

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    IconBadge(systemImage: sample.annotation.activity.systemImage)
                    Text(verbatim: sample.annotation.activity.title)
                        .font(.headline)
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer(minLength: Theme.Spacing.row)
                    Text(verbatim: Formatting.time(sample.fix.timestamp))
                        .font(Theme.Typography.rowValue)
                        .foregroundStyle(Theme.Palette.ink)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(width: 30, height: 30)
                            .background(Theme.Palette.sunken, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("map.sample.close")
                }

                HStack(spacing: 8) {
                    tile(Formatting.speed(sample.fix.validSpeed), "status.lastFix.speed")
                    tile(Formatting.accuracy(sample.fix.horizontalAccuracy), "status.lastFix.accuracy")
                    tile(Formatting.altitude(sample.fix.altitude), "status.lastFix.altitude")
                    tile(Formatting.battery(sample.annotation.batteryLevel), "common.battery")
                }

                RowSeparator()

                Text(verbatim: Formatting.coordinate(sample.fix.latitude, sample.fix.longitude))
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .textSelection(.enabled)
            }
        }
    }

    private func tile(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Theme.Palette.sunken, in: .rect(cornerRadius: Theme.Radius.tile))
        .accessibilityElement(children: .combine)
    }
}

/// The round map buttons, matched to `MapUserLocationButton`'s own size so the
/// stack reads as one control group.
private struct MapControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Theme.Palette.ink : Theme.Palette.inkMuted.opacity(0.5))
            .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
            .background(Theme.Palette.surface, in: .rect(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Splits the available width between its subviews in proportion to
/// `weights`, which is what makes the breakdown bar a breakdown.
///
/// `layoutPriority` looks like it would do this and does not: it decides who
/// gets squeezed when space runs short, not how much of it each one gets, so
/// the bar came out a single block of the largest activity's colour.
struct ProportionalHStack: Layout {
    var spacing: CGFloat = 3
    var weights: [Double]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let usable = max(0, bounds.width - gaps)
        // A weight missing or non-positive falls back to an equal share, so a
        // zero-distance leg still draws rather than collapsing to a hairline.
        let resolved = (0..<subviews.count).map { index -> Double in
            let weight = index < weights.count ? weights[index] : 0
            return weight > 0 ? weight : 0
        }
        let total = resolved.reduce(0, +)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let share = total > 0 ? resolved[index] / total : 1 / Double(subviews.count)
            let width = usable * CGFloat(share)
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// A row that wraps onto the next line when it runs out of width. The legend
/// has between one and four entries and every language spells them
/// differently, so a fixed column count truncates somewhere.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview {
    MapView()
        .environment(\.trackingController, PreviewTrackingController())
}
