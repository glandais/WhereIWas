import SwiftUI

/// Export a date range or a session as GPX or JSON, then share it.
struct ExportView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case today, week, all, custom, session
        var id: String { rawValue }
        var title: String {
            switch self {
            // Its own key, not the `Today` of the Status screen: this one is a
            // segment of a five-way segmented picker and has to stay short, or
            // it truncates ("Aujourd’hui" → "Aujour…").
            case .today: return String(localized: "scope.today", defaultValue: "Today",
                                       comment: "Segment of the export scope picker; keep it short")
            case .week: return String(localized: "export.scope.week", defaultValue: "7 days")
            case .all: return String(localized: "export.scope.all", defaultValue: "All")
            case .custom: return String(localized: "export.scope.range", defaultValue: "Range")
            case .session: return String(localized: "export.session.label", defaultValue: "Session")
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
            ScrollViewReader { proxy in
                Form {
                    Section("export.what") {
                        Picker("export.scope.label", selection: $scope) {
                            ForEach(Scope.allCases) { Text(verbatim: $0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if scope == .custom {
                            DatePicker("export.range.from", selection: $customStart, in: ...customEnd)
                            DatePicker("export.range.to", selection: $customEnd, in: customStart...Date.now)
                        }
                        if scope == .session {
                            if sessions.isEmpty {
                                Text("export.sessions.empty")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("export.session.label", selection: $selectedSession) {
                                    ForEach(sessions) { session in
                                        Text(verbatim: sessionTitle(session)).tag(Optional(session.id))
                                    }
                                }
                                .pickerStyle(.navigationLink)
                            }
                        }
                    }

                    Section("common.format") {
                        Picker("common.format", selection: $format) {
                            ForEach(ExportFormat.allCases) { f in
                                Label(f.title, systemImage: f.systemImage).tag(f)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Text(format == .gpx
                             ? "export.format.gpxDescription"
                             : "export.format.jsonDescription")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Button {
                            Task { await export() }
                        } label: {
                            HStack {
                                Label(String(localized: "export.prepare",
                                             defaultValue: "Prepare \(format.title) file"),
                                      systemImage: "doc.badge.gearshape")
                                if isExporting {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isExporting || (scope == .session && selectedSession == nil))

                        if let url = exportedURL, exportedFor == exportKey {
                            ShareLink(item: url, preview: SharePreview(url.lastPathComponent, image: Image(systemName: format.systemImage))) {
                                Label(String(localized: "common.share",
                                             defaultValue: "Share \(url.lastPathComponent)"),
                                      systemImage: "square.and.arrow.up")
                            }
                            if let size = fileSize(url) {
                                LabeledContent("export.fileSize", value: size)
                            }
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    } footer: {
                        Text("export.footer")
                    }

                    if !sessions.isEmpty {
                        Section("common.sessions") {
                            ForEach(sessions) { session in
                                SessionRow(session: session)
                            }
                        }
                    }
                }
                .navigationTitle("common.export")
                .task {
                    #if SCREENSHOTS
                    // The whole history, not today: the demo dataset spans three
                    // days, and "Today" would export the drive in progress alone.
                    if ScreenshotMode.isActive { scope = .all }
                    #endif
                    await loadSessions()
                    #if SCREENSHOTS
                    // Show a prepared file rather than an inert button.
                    if ScreenshotMode.isActive { await export() }
                    // And scroll to what the screen is actually worth showing. The
                    // format picker and its help text sit above the fold, so an
                    // untouched capture of this screen reads like a settings page;
                    // the session list — dates, durations, distances — is the part
                    // that sells, and is exactly what a user sees after one flick.
                    // The target is the last session row rather than the section:
                    // `Form` is a list, and `scrollTo` resolves rows, so an `.id`
                    // on a `Section` is not a destination. Rows are identified by
                    // the summary's own id, so there is nothing else to tag.
                    if ScreenshotMode.isActive, let last = sessions.last?.id {
                        try? await Task.sleep(for: .milliseconds(300))
                        withAnimation(.none) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                    #endif
                }
                .refreshable { await loadSessions() }
            }
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
                    Text("export.session.open")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: .capsule)
                        .foregroundStyle(.green)
                }
            }
            Text(verbatim: String(localized: "export.session.summary",
                                  defaultValue: "\(Formatting.count(session.sampleCount)) samples · \(Formatting.distance(session.distanceMeters)) · \(durationText)"))
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
