import SwiftUI

/// Reader for the opt-in audit trail: the data received, the tests run on it
/// and the state changes that followed.
///
/// The screen is deliberately dense and filterable rather than pretty: it is
/// read after an incident, to answer "why is there no fix between 14:02 and
/// 14:20 ?".
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
    @State private var exportFormat: AuditExportFormat = .text
    @State private var isExporting = false
    @State private var showClearConfirmation = false

    /// Identifies the selection a file was produced for, so a stale export is
    /// not offered after the filters or the format changed.
    private var exportKey: String {
        let categories = selectedCategories.map(\.rawValue).sorted().joined(separator: ",")
        return "\(categories)|\(minimumSeverity.rawValue)|\(exportFormat.rawValue)"
    }

    private var query: AuditQuery {
        AuditQuery(categories: selectedCategories.isEmpty ? nil : selectedCategories,
                   minimumSeverity: minimumSeverity,
                   limit: 1_000)
    }

    var body: some View {
        Group {
            if !controller.settings.auditEnabled && events.isEmpty {
                disabledState
            } else {
                list
            }
        }
        .navigationTitle("Audit trail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: query) { await load() }
        .refreshable { await load() }
        .confirmationDialog("Delete the whole audit trail?",
                            isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                Task {
                    _ = await controller.clearAudit()
                    await load()
                }
            }
        } message: {
            Text("Location samples are not affected. Export first if you need the trail.")
        }
    }

    // MARK: Content

    private var disabledState: some View {
        ContentUnavailableView {
            Label("Audit trail is off", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Turn it on in Settings to record every fix received, every validation test run on it, and every state change.")
        }
    }

    private var list: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                filterControls
            }
            if let exportURL, exportedFor == exportKey {
                Section {
                    ShareLink(item: exportURL,
                              preview: SharePreview(exportURL.lastPathComponent,
                                                    image: Image(systemName: "doc.text.magnifyingglass"))) {
                        Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Written to a temporary folder: \(events.count) events plus the settings in force at export time.")
                }
            }
            Section {
                if events.isEmpty {
                    Text(isLoading ? "Loading…" : "No events match these filters.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        NavigationLink {
                            AuditEventDetailView(event: event)
                        } label: {
                            AuditEventRow(event: event)
                        }
                    }
                }
            } header: {
                Text("\(events.count) shown · \(storedCount) stored")
            } footer: {
                Text("Newest first. Tap an event for its full payload.")
            }
        }
        .listStyle(.plain)
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Minimum severity", selection: $minimumSeverity) {
                ForEach(AuditSeverity.allCases, id: \.rawValue) { severity in
                    Text(verbatim: severity.displayName).tag(severity)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AuditCategory.allCases) { category in
                        let selected = selectedCategories.contains(category)
                        Button {
                            if selected {
                                selectedCategories.remove(category)
                            } else {
                                selectedCategories.insert(category)
                            }
                        } label: {
                            Label(category.displayName, systemImage: category.symbolName)
                                .font(.footnote)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Format", selection: $exportFormat) {
                    ForEach(AuditExportFormat.allCases) { format in
                        Text(verbatim: format.displayName).tag(format)
                    }
                }
                Button(String(localized: "audit.export.action", defaultValue: "Export",
                              comment: "Menu action that exports the audit trail; a verb"),
                       systemImage: "square.and.arrow.up") {
                    Task { await export() }
                }
                .disabled(isExporting || events.isEmpty)
                Divider()
                Button("Delete trail", systemImage: "trash", role: .destructive) {
                    showClearConfirmation = true
                }
                .disabled(storedCount == 0)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            events = try await controller.auditEvents(matching: query)
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
            exportURL = try await controller.exportAudit(format: exportFormat, query: query)
            exportedFor = exportKey
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Rows

private struct AuditEventRow: View {
    let event: AuditEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: event.category.symbolName)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(verbatim: event.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(color)
                Spacer()
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: event.message)
                .font(.callout)
                .lineLimit(2)
            if let phase = event.phase {
                Text(verbatim: phase.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch event.severity {
        case .debug: return .secondary
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Detail

private struct AuditEventDetailView: View {
    let event: AuditEvent

    var body: some View {
        List {
            Section("Event") {
                LabeledContent("Name", value: event.name)
                LabeledContent("Category", value: event.category.displayName)
                LabeledContent("Severity", value: event.severity.displayName)
                LabeledContent("Time") {
                    Text(event.timestamp, format: .dateTime.year().month().day()
                        .hour().minute().second())
                }
                if let phase = event.phase {
                    LabeledContent("Phase", value: phase.rawValue)
                }
                if let battery = event.batteryLevel {
                    LabeledContent("Battery", value: battery.formatted(.percent.precision(.fractionLength(0))))
                }
            }
            Section("Message") {
                Text(verbatim: event.message)
            }
            if !checks.isEmpty {
                Section("Tests performed") {
                    ForEach(checks, id: \.key) { detail in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: detail.key.replacingOccurrences(of: "check.", with: ""))
                                .font(.caption.monospaced())
                            Text(verbatim: detail.value)
                                .font(.footnote)
                                .foregroundStyle(verdictColor(detail.value))
                        }
                    }
                }
            }
            if !data.isEmpty {
                Section("Data") {
                    ForEach(data, id: \.key) { detail in
                        LabeledContent(detail.key) {
                            Text(verbatim: detail.value)
                                .font(.footnote.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var checks: [AuditDetail] { event.details.filter { $0.key.hasPrefix("check.") } }
    private var data: [AuditDetail] { event.details.filter { !$0.key.hasPrefix("check.") } }

    private func verdictColor(_ value: String) -> Color {
        if value.hasPrefix("failed") { return .red }
        if value.hasPrefix("passed") { return .green }
        return .secondary
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
