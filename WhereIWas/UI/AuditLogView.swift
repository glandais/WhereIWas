import SwiftUI

/// Reader for the opt-in technical log: the data received, the tests run on it
/// and the state changes that followed.
///
/// The screen stays dense and filterable rather than pretty: it is read after
/// an incident, to answer "why is there no fix between 14:02 and 14:20?". The
/// filters are pinned under the title so they never scroll away from the rows
/// they govern.
struct AuditLogView: View {
    @Environment(\.trackingController) private var controller

    @State private var events: [AuditEvent] = []
    @State private var selectedCategories: Set<AuditCategory> = []
    @State private var minimumSeverity: AuditSeverity = .debug
    @State private var storedCount = 0
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var exportURL: URL?
    @State private var exportedFor: String?
    @State private var exportFormat: AuditExportFormat = .json
    /// Gzip the export. On by default: a week of trail is tens of megabytes,
    /// and every share target handles a `.gz` better than it handles that.
    @State private var compressExport = true
    @State private var isExporting = false
    @State private var showClearConfirmation = false

    /// Identifies the selection a file was produced for, so a stale export is
    /// not offered after the filters or the format changed.
    private var exportKey: String {
        let categories = selectedCategories.map(\.rawValue).sorted().joined(separator: ",")
        return "\(categories)|\(minimumSeverity.rawValue)|\(exportFormat.rawValue)|\(compressExport)"
    }

    /// What the list shows. Capped: the trail can hold tens of thousands of
    /// rows and the screen is read by scrolling, not by exhausting it.
    private var listQuery: AuditQuery {
        AuditQuery(categories: selectedCategories.isEmpty ? nil : selectedCategories,
                   minimumSeverity: minimumSeverity,
                   limit: 1_000)
    }

    /// What the export writes: the same filters, no cap.
    ///
    /// The list's cap has no business here. A ride that used to fit in a
    /// thousand rows now fills them in half an hour — the export was silently
    /// keeping the last 36 minutes of a two-hour ride, which is precisely the
    /// span someone exporting the trail after an incident needs to see.
    private var exportQuery: AuditQuery {
        AuditQuery(categories: selectedCategories.isEmpty ? nil : selectedCategories,
                   minimumSeverity: minimumSeverity,
                   limit: 0)
    }

    var body: some View {
        Group {
            if !controller.settings.auditEnabled && events.isEmpty {
                disabledState
            } else {
                list
            }
        }
        .themedBackground()
        .navigationTitle("audit.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: listQuery) { await load() }
        .refreshable { await load() }
        .confirmationDialog("audit.clear.title",
                            isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("audit.clear.confirm", role: .destructive) {
                Task {
                    _ = await controller.clearAudit()
                    await load()
                }
            }
        } message: {
            Text("audit.clear.message")
        }
    }

    // MARK: Content

    private var disabledState: some View {
        ContentUnavailableView {
            Label("audit.disabled.title", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("audit.disabled.description")
        }
    }

    private var list: some View {
        List {
            if let loadError {
                AlertCard(title: String(localized: "audit.load.failed", defaultValue: "Could not read the log",
                                        comment: "Title of the card shown when reading the audit trail threw"),
                          message: loadError,
                          tone: .critical,
                          systemImage: "exclamationmark.triangle.fill")
                    .auditRow()
                    .padding(.bottom, Theme.Spacing.row)
            }

            if let exportURL, exportedFor == exportKey {
                VStack(alignment: .leading, spacing: 6) {
                    ShareLink(item: exportURL,
                              preview: SharePreview(exportURL.lastPathComponent,
                                                    image: Image(systemName: "doc.text.magnifyingglass"))) {
                        Label(String(localized: "common.share",
                                     defaultValue: "Share \(exportURL.lastPathComponent)"),
                              systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Text("audit.export.footer")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .auditRow()
                .padding(.bottom, Theme.Spacing.row)
            }

            if events.isEmpty {
                Text(isLoading ? "common.loading" : "audit.list.empty")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .auditRow()
            } else {
                ForEach(events) { event in
                    ZStack {
                        // A `NavigationLink` label would add the list's own
                        // chevron and inset on top of the row's own layout;
                        // an overlaid link keeps the row exactly as drawn.
                        AuditEventRow(event: event)
                        NavigationLink {
                            AuditEventDetailView(event: event)
                        } label: {
                            EmptyView()
                        }
                        .opacity(0)
                    }
                    .auditRow()
                    .overlay(alignment: .bottom) { RowSeparator() }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("audit.minimumSeverity", selection: $minimumSeverity) {
                ForEach(AuditSeverity.allCases, id: \.rawValue) { severity in
                    Text(verbatim: severity.displayName).tag(severity)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(AuditCategory.allCases) { category in
                        let selected = selectedCategories.contains(category)
                        Button {
                            if selected {
                                selectedCategories.remove(category)
                            } else {
                                selectedCategories.insert(category)
                            }
                        } label: {
                            Text(verbatim: category.displayName)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.ink)
                                .padding(.horizontal, 13)
                                .frame(minHeight: 34)
                                .background(selected ? Theme.Palette.accent.opacity(0.12) : Theme.Palette.surface,
                                            in: .capsule)
                                .overlay {
                                    Capsule().strokeBorder(selected ? Theme.Palette.accent : Theme.Palette.hairline,
                                                           lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            // The chips scroll edge to edge; the padding above puts them back
            // in line with everything else.
            .padding(.horizontal, -Theme.Spacing.card)

            Text(verbatim: String(localized: "audit.list.counts",
                                  defaultValue: "\(events.count) shown · \(storedCount) stored"))
                .font(Theme.Typography.code)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { RowSeparator() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("common.format", selection: $exportFormat) {
                    ForEach(AuditExportFormat.allCases) { format in
                        Text(verbatim: format.displayName).tag(format)
                    }
                }
                Toggle(String(localized: "audit.export.compress", defaultValue: "Compress (.gz)",
                              comment: "Export option: gzip the exported audit file"),
                       isOn: $compressExport)
                Button(String(localized: "audit.export.action", defaultValue: "Export",
                              comment: "Menu action that exports the audit trail; a verb"),
                       systemImage: "square.and.arrow.up") {
                    Task { await export() }
                }
                .disabled(isExporting || events.isEmpty)
                Divider()
                Button("audit.clear.action", systemImage: "trash", role: .destructive) {
                    showClearConfirmation = true
                }
                .disabled(storedCount == 0)
            } label: {
                Label("audit.toolbar.actions", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            events = try await controller.auditEvents(matching: listQuery)
            storedCount = try await controller.auditCount()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        do {
            exportURL = try await controller.exportAudit(format: exportFormat,
                                                        compressed: compressExport,
                                                        query: exportQuery)
            exportedFor = exportKey
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private extension View {
    /// The list row chrome the audit screen wants: no system background, no
    /// system separator, its own margins.
    func auditRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 10, leading: Theme.Spacing.card,
                                      bottom: 10, trailing: Theme.Spacing.card))
    }
}

// MARK: - Rows

private struct AuditEventRow: View {
    let event: AuditEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: event.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(tone.color)
                Spacer(minLength: Theme.Spacing.tight)
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Text(verbatim: Formatting.auditSummary(event))
                .font(.callout)
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(2)
            if let phase = event.phase {
                Text(verbatim: phase.title)
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var tone: Theme.Tone {
        switch event.severity {
        case .debug: return .neutral
        case .info: return .neutral
        case .warning: return .caution
        case .error: return .critical
        }
    }
}

// MARK: - Detail

private struct AuditEventDetailView: View {
    let event: AuditEvent

    var body: some View {
        DetailScreen(title: "audit.detail.event") {
            headline

            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                    SectionHeader("audit.detail.tests")
                    RowCard {
                        ForEach(Array(checks.enumerated()), id: \.element.key) { index, detail in
                            if index > 0 { RowSeparator() }
                            checkRow(detail)
                        }
                    }
                }
            }

            if !data.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                    SectionHeader("audit.detail.data")
                    RowCard {
                        ForEach(Array(data.enumerated()), id: \.element.key) { index, detail in
                            if index > 0 { RowSeparator() }
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.row) {
                                Text(verbatim: detail.key)
                                    .font(Theme.Typography.code)
                                    .foregroundStyle(Theme.Palette.inkMuted)
                                Spacer(minLength: Theme.Spacing.tight)
                                Text(verbatim: detail.value)
                                    .font(Theme.Typography.code)
                                    .foregroundStyle(Theme.Palette.ink)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.horizontal, Theme.Spacing.card)
                            .padding(.vertical, 10)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .navigationTitle(event.name)
    }

    /// The whole event in one card: what it says, how serious it is, and when.
    /// The old screen spread those over six labelled rows the reader had to
    /// reassemble.
    private var headline: some View {
        Card(tone: tone) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: event.category.symbolName)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(tone.color)
                    Text(verbatim: "\(event.severity.displayName) · \(event.category.displayName)")
                        .sectionLabelStyle()
                        .foregroundStyle(tone.color)
                }
                Text(verbatim: Formatting.auditSummary(event))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(event.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                        .font(Theme.Typography.code)
                        .foregroundStyle(Theme.Palette.inkMuted)
                    if let phase = event.phase {
                        Text(verbatim: phase.title)
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                    if let battery = event.batteryLevel {
                        Text(verbatim: Formatting.battery(battery))
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
            }
        }
    }

    private func checkRow(_ detail: AuditDetail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.row) {
            Image(systemName: verdictSymbol(detail.value))
                .font(.caption.weight(.bold))
                // The symbol and the colour read the *raw* verdict: the
                // displayed one is translated.
                .foregroundStyle(verdictTone(detail.value).color)
            Text(verbatim: Formatting.checkName(detail.key))
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: Theme.Spacing.tight)
            Text(verbatim: Formatting.checkVerdict(detail.value))
                .font(.caption)
                .foregroundStyle(verdictTone(detail.value).color)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var tone: Theme.Tone {
        switch event.severity {
        case .debug, .info: return .neutral
        case .warning: return .caution
        case .error: return .critical
        }
    }

    private var checks: [AuditDetail] { event.details.filter { $0.key.hasPrefix("check.") } }
    private var data: [AuditDetail] { event.details.filter { !$0.key.hasPrefix("check.") } }

    private func verdictTone(_ value: String) -> Theme.Tone {
        if value.hasPrefix("failed") { return .critical }
        if value.hasPrefix("passed") { return .positive }
        return .neutral
    }

    private func verdictSymbol(_ value: String) -> String {
        if value.hasPrefix("failed") { return "xmark" }
        if value.hasPrefix("passed") { return "checkmark" }
        return "minus"
    }
}

#Preview("Audit trail") {
    NavigationStack {
        AuditLogView()
    }
    .environment(\.trackingController, {
        let controller = PreviewTrackingController()
        controller.settings.auditEnabled = true
        return controller
    }())
}
