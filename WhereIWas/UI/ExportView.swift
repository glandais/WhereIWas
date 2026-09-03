import SwiftUI

/// Export a date range or a session as GPX or JSON, then share it.
struct ExportView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case today, week, all, custom, session
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return String(localized: "Today")
            case .week: return String(localized: "7 days")
            case .all: return String(localized: "All")
            case .custom: return String(localized: "Range")
            case .session: return String(localized: "Session")
            }
        }
    }

    @Environment(\.trackingController) private var controller

    @State private var scope: Scope = .today
    @State private var format: ExportFormat = .gpx
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var customEnd: Date = .now
    @State private var sessions: [TrackingSessionSummary] = []
    @State private var selectedSession: UUID?

    @State private var exportedURL: URL?
    @State private var exportedFor: String?
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if scope == .custom {
                        DatePicker("From", selection: $customStart, in: ...customEnd)
                        DatePicker("To", selection: $customEnd, in: customStart...Date.now)
                    }
                    if scope == .session {
                        if sessions.isEmpty {
                            Text("No sessions recorded yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Session", selection: $selectedSession) {
                                ForEach(sessions) { session in
                                    Text(verbatim: sessionTitle(session)).tag(Optional(session.id))
                                }
                            }
                            .pickerStyle(.navigationLink)
                        }
                    }
                }

                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { f in
                            Label(f.title, systemImage: f.systemImage).tag(f)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text(format == .gpx
                         ? "GPX 1.1 track with elevation, time and extensions (speed, course, accuracy, activity, battery). Opens in most mapping tools."
                         : "JSON array of every stored sample with all fields, including upload status and sequence ids.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await export() }
                    } label: {
                        HStack {
                            Label("Prepare \(format.title) file", systemImage: "doc.badge.gearshape")
                            if isExporting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExporting || (scope == .session && selectedSession == nil))

                    if let url = exportedURL, exportedFor == exportKey {
                        ShareLink(item: url, preview: SharePreview(url.lastPathComponent, image: Image(systemName: format.systemImage))) {
                            Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                        if let size = fileSize(url) {
                            LabeledContent("Size", value: size)
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                } footer: {
                    Text("Files are written to a temporary folder and can be shared with AirDrop, Files, Mail or any other app.")
                }

                if !sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Export")
            .task { await loadSessions() }
            .refreshable { await loadSessions() }
        }
    }

    // MARK: Logic

    /// Identifies the current selection so a stale file is not offered
    /// after the user changed scope/format.
    private var exportKey: String {
        "\(scope.rawValue)|\(format.rawValue)|\(selectedSession?.uuidString ?? "")|\(customStart.timeIntervalSince1970)|\(customEnd.timeIntervalSince1970)"
    }

    private var interval: DateInterval? {
        let cal = Calendar.current
        let now = Date.now
        switch scope {
        case .today:
            let start = cal.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .week:
            let start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now)) ?? now
            return DateInterval(start: start, end: now)
        case .custom:
            return DateInterval(start: customStart, end: max(customEnd, customStart))
        case .all, .session:
            return nil
        }
    }

    private func export() async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let key = exportKey
            let url = try await controller.export(format: format,
                                                  sessionID: scope == .session ? selectedSession : nil,
                                                  interval: interval)
            exportedURL = url
            exportedFor = key
        } catch {
            exportedURL = nil
            errorMessage = error.localizedDescription
        }
    }

    private func loadSessions() async {
        sessions = (try? await controller.sessions()) ?? []
        if selectedSession == nil { selectedSession = sessions.first?.id }
    }

    private func sessionTitle(_ session: TrackingSessionSummary) -> String {
        "\(Formatting.dateTime(session.startedAt)) · \(Formatting.distance(session.distanceMeters))"
    }

    private func fileSize(_ url: URL) -> String? {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return ByteCountFormatStyle().format(Int64(bytes))
    }
}

private struct SessionRow: View {
    let session: TrackingSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Formatting.dateTime(session.startedAt))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if session.endedAt == nil {
                    Text("Open")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: .capsule)
                        .foregroundStyle(.green)
                }
            }
            Text("\(Formatting.count(session.sampleCount)) samples · \(Formatting.distance(session.distanceMeters)) · \(durationText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var durationText: String {
        Formatting.duration((session.endedAt ?? .now).timeIntervalSince(session.startedAt))
    }
}

#Preview {
    ExportView()
        .environment(\.trackingController, PreviewTrackingController())
}
