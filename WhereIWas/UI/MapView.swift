import MapKit
import SwiftUI

/// Map of one day's track. A day picker at the top, a polyline of the
/// selected day's samples, the user's live location and a summary bar.
struct MapView: View {
    @Environment(\.trackingController) private var controller

    @State private var day: Date = Calendar.current.startOfDay(for: .now)
    @State private var samples: [StoredLocationSample] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedSequence: Int64?

    private var calendar: Calendar { .current }
    private var isToday: Bool { calendar.isDateInToday(day) }

    private var coordinates: [CLLocationCoordinate2D] {
        samples.map { CLLocationCoordinate2D(latitude: $0.fix.latitude, longitude: $0.fix.longitude) }
    }

    private var selectedSample: StoredLocationSample? {
        guard let selectedSequence else { return nil }
        return samples.first { $0.sequence == selectedSequence }
    }

    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selectedSequence) {
                UserAnnotation()

                if coordinates.count > 1 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }

                if let first = samples.first {
                    Marker("Start", systemImage: "flag", coordinate: coordinate(of: first))
                        .tint(.green)
                        .tag(first.sequence)
                }
                if let last = samples.last, samples.count > 1 {
                    Marker("End", systemImage: "flag.checkered", coordinate: coordinate(of: last))
                        .tint(.red)
                        .tag(last.sequence)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls {
                #if SCREENSHOTS
                // Nothing is locating us in screenshot mode, so the button
                // would spin forever in the corner of every shot.
                if !ScreenshotMode.isActive { MapUserLocationButton() }
                #else
                MapUserLocationButton()
                #endif
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .top) { dayPicker }
            .safeAreaInset(edge: .bottom) { summaryBar }
            .overlay {
                if isLoading {
                    ProgressView()
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                } else if samples.isEmpty {
                    ContentUnavailableView {
                        Label("No track", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    } description: {
                        if let loadError {
                            Text(verbatim: loadError)
                        } else {
                            Text("No samples recorded on \(Formatting.day(day)).")
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                    .padding(32)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fit track", systemImage: "arrow.up.left.and.arrow.down.right") { fitTrack() }
                        .disabled(samples.isEmpty)
                }
            }
            .task(id: day) { await load() }
            .task(id: controller.status.acceptedCount) {
                // Live refresh while looking at today.
                if isToday, !samples.isEmpty || controller.status.acceptedCount > 0 { await load(fit: false) }
            }
        }
    }

    // MARK: Subviews

    private var dayPicker: some View {
        HStack {
            Button("Previous day", systemImage: "chevron.left") { shift(by: -1) }
                .labelStyle(.iconOnly)
            Spacer()
            DatePicker("Day", selection: $day, in: ...Date.now, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
            Spacer()
            Button("Next day", systemImage: "chevron.right") { shift(by: 1) }
                .labelStyle(.iconOnly)
                .disabled(isToday)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var summaryBar: some View {
        if let sample = selectedSample {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(sample.annotation.activity.title, systemImage: sample.annotation.activity.systemImage)
                    Spacer()
                    Text(Formatting.time(sample.fix.timestamp))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold))
                Text("\(Formatting.speed(sample.fix.validSpeed)) · \(Formatting.accuracy(sample.fix.horizontalAccuracy)) · \(Formatting.altitude(sample.fix.altitude)) · battery \(Formatting.battery(sample.annotation.batteryLevel))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Formatting.coordinate(sample.fix.latitude, sample.fix.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        } else if !samples.isEmpty {
            HStack(spacing: 16) {
                stat("Points", Formatting.count(samples.count))
                stat("Distance", Formatting.distance(pathLength))
                if let first = samples.first, let last = samples.last {
                    stat("Span", "\(Formatting.time(first.fix.timestamp)) – \(Formatting.time(last.fix.timestamp))")
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
        let coords = coordinates
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

#Preview {
    MapView()
        .environment(\.trackingController, PreviewTrackingController())
}
