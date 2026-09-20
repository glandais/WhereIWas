import SwiftUI

/// Export a period or a session as GPX or JSON, then share it.
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
                CardScreen(title: "common.export") {
                    scopeSection
                    formatSection
                    fileSection
                    if !sessions.isEmpty { sessionsSection }
                }
                .navigationBarHidden(true)
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
                    // And scroll to what the screen is actually worth showing:
                    // the session list — dates, durations, distances — is the
                    // part that sells, and is exactly what a user sees after
                    // one flick. The anchor is the last session row's own id,
                    // which survives the move from `Form` to `ScrollView`.
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

    // MARK: Sections

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("export.what")
            Picker("export.scope.label", selection: $scope) {
                ForEach(Scope.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if scope == .custom {
                RowCard {
                    DatePicker("export.range.from", selection: $customStart, in: ...customEnd)
                        .padding(.horizontal, Theme.Spacing.card)
                        .padding(.vertical, 8)
                    RowSeparator()
                    DatePicker("export.range.to", selection: $customEnd, in: customStart...Date.now)
                        .padding(.horizontal, Theme.Spacing.card)
                        .padding(.vertical, 8)
                }
            } else if scope == .session {
                sessionPicker
            }

            if let summary = scopeSummary {
                Text(verbatim: summary)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 2)
            }
        }
    }

    @ViewBuilder
    private var sessionPicker: some View {
        if sessions.isEmpty {
            Card {
                Text("export.sessions.empty")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        } else {
            RowCard {
                Picker("export.session.label", selection: $selectedSession) {
                    ForEach(sessions) { session in
                        Text(verbatim: sessionTitle(session)).tag(Optional(session.id))
                    }
                }
                .pickerStyle(.navigationLink)
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, 8)
            }
        }
    }

    /// One line saying what the current selection actually covers, so the
    /// button below is never pressed blind.
    private var scopeSummary: String? {
        switch scope {
        case .all:
            let stats = controller.status.stats
            guard stats.totalSamples > 0, let oldest = stats.oldestSample else { return nil }
            return String(localized: "export.scope.allSummary",
                          defaultValue: "\(Formatting.count(stats.sessionCount)) sessions · \(Formatting.count(stats.totalSamples)) points · since \(Formatting.day(oldest))",
                          comment: "Summary under the export scope picker when everything is selected")
        case .today, .week, .custom:
            guard let interval else { return nil }
            return String(localized: "export.scope.rangeSummary",
                          defaultValue: "\(Formatting.dateTime(interval.start)) → \(Formatting.dateTime(interval.end))",
                          comment: "Summary under the export scope picker: the period covered")
        case .session:
            guard let id = selectedSession, let session = sessions.first(where: { $0.id == id }) else { return nil }
            return String(localized: "export.session.summary",
                          defaultValue: "\(Formatting.count(session.sampleCount)) samples · \(Formatting.distance(session.distanceMeters)) · \(duration(of: session))")
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("common.format")
            // A `Grid` rather than an `HStack`: the two descriptions are not
            // the same length, and a stack left the shorter tile visibly
            // shorter. A grid row equalises its cells' heights.
            Grid(horizontalSpacing: Theme.Spacing.row, verticalSpacing: 0) {
                GridRow {
                    ForEach(ExportFormat.allCases) { candidate in
                        FormatTile(format: candidate,
                                   isSelected: format == candidate) { format = candidate }
                    }
                }
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            if let url = exportedURL, exportedFor == exportKey {
                RowCard {
                    HStack(spacing: 12) {
                        IconBadge(systemImage: format.systemImage)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: url.lastPathComponent)
                                .font(Theme.Typography.code)
                                .foregroundStyle(Theme.Palette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(verbatim: [fileSize(url), String(localized: "export.file.ready", defaultValue: "ready", comment: "State of a freshly written export file")]
                                    .compactMap { $0 }
                                    .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                        Spacer(minLength: Theme.Spacing.row)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Tone.positive.color)
                    }
                    .padding(.horizontal, Theme.Spacing.card)
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)

                    RowSeparator()

                    ShareLink(item: url,
                              preview: SharePreview(url.lastPathComponent,
                                                    image: Image(systemName: format.systemImage))) {
                        Label("export.share.action", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Button {
                    Task { await export() }
                } label: {
                    HStack(spacing: 8) {
                        if isExporting {
                            ProgressView().tint(Theme.Palette.heroInk)
                        } else {
                            Image(systemName: "doc.badge.gearshape")
                        }
                        Text(verbatim: String(localized: "export.prepare",
                                              defaultValue: "Prepare \(format.title) file"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isExporting || (scope == .session && selectedSession == nil))
            }

            if let errorMessage {
                AlertCard(title: String(localized: "export.failed.title", defaultValue: "Export failed",
                                        comment: "Title of the card shown when writing the export file threw"),
                          message: errorMessage,
                          tone: .critical,
                          systemImage: "exclamationmark.triangle.fill")
            }

            Text("export.footer")
                .font(.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 2)
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader(title: "common.sessions") {
                Text(verbatim: Formatting.count(sessions.count))
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            RowCard {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { RowSeparator() }
                    SessionRow(session: session)
                        .id(session.id)
                }
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

    private func duration(of session: TrackingSessionSummary) -> String {
        Formatting.duration((session.endedAt ?? .now).timeIntervalSince(session.startedAt))
    }

    private func fileSize(_ url: URL) -> String? {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return ByteCountFormatStyle().format(Int64(bytes))
    }
}

// MARK: - Pieces

/// One of the two format choices, as a tile carrying its own explanation —
/// the old inline picker put the description under both and made the reader
/// work out which one it applied to.
private struct FormatTile: View {
    let format: ExportFormat
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: format.systemImage)
                        .font(.footnote.weight(.semibold))
                    Text(verbatim: format.title)
                        .font(.headline)
                }
                .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.ink)
                Text(format == .gpx ? "export.format.gpxDescription" : "export.format.jsonDescription")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(isSelected ? Theme.Palette.accent.opacity(0.08) : Theme.Palette.surface,
                        in: .rect(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(isSelected ? Theme.Palette.accent : Theme.Palette.hairline,
                                  lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct SessionRow: View {
    let session: TrackingSessionSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.row) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: Formatting.dateTime(session.startedAt))
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.ink)
                Text(verbatim: String(localized: "export.session.summary",
                                      defaultValue: "\(Formatting.count(session.sampleCount)) samples · \(Formatting.distance(session.distanceMeters)) · \(durationText)"))
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer(minLength: Theme.Spacing.row)
            if session.endedAt == nil {
                StatusPill(text: String(localized: "export.session.open", defaultValue: "Ongoing"),
                           tone: .positive,
                           filled: true)
            }
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 12)
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
