import SwiftUI
import GlookoServiceKit

@MainActor final class DiagnosticsModel: ObservableObject {
    let service: GlookoService
    @Published var data: GlookoService.DiagnosticSnapshot
    @Published var snapshot: GlookoService.Snapshot
    @Published var checking = false
    init(service: GlookoService) { self.service = service; data = service.diagnostics; snapshot = service.snapshot }
    func refresh() { data = service.diagnostics; snapshot = service.snapshot }
    func check() {
        guard !checking else { return }
        checking = true
        Task { [weak self, service] in
            await service.checkGlookoNow()
            self?.refresh(); self?.checking = false
        }
    }
    func export(build: String) -> String {
        refresh()
        var lines = ["Loop → Glooko diagnostics", "Build: \(build)",
            "Generated: \(Date())",
            "Dose/settings queries drained: \(data.doseQueryDrained)/\(data.settingsQueryDrained)"]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let report = data.state.lastInspection, let encoded = try? encoder.encode(report) {
            lines += ["Latest read-only verification (JSON):", String(decoding: encoded, as: UTF8.self)]
        }
        for error in [data.storageError, data.state.inspectionError, snapshot.status.lastError,
                      snapshot.status.carbError, snapshot.status.glucoseError].compactMap({ $0 }) {
            lines.append("Error: " + GlookoClient.redact(error))
        }
        lines += data.state.events.map { "\($0.date) [\($0.category)] \($0.message)" }
        return lines.joined(separator: "\n")
    }
}

struct DiagnosticsView: View {
    @StateObject private var model: DiagnosticsModel
    @Environment(\.dismiss) private var dismiss
    @State private var sharedReport: String?
    @State private var showingShare = false
    private let build: String
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    init(service: GlookoService, build: String) { _model = StateObject(wrappedValue: DiagnosticsModel(service: service)); self.build = build }
    private func time(_ value: Date?) -> String {
        guard let value else { return "Not recorded" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM HH:mm:ss"
        return f.string(from: value)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title); Spacer(); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("This fetches Glooko's stored insulin and acknowledged glucose again. It does not send data or prove which screen the Glooko app is displaying.")) {
                    Button(model.checking || model.data.checking ? "Checking Glooko…" : "Check Glooko now") { model.check() }
                        .disabled(model.checking || model.data.checking).accessibilityIdentifier("glooko-live-check")
                    if let report = model.data.state.lastInspection {
                        row("Last check", time(report.checkedAt))
                        Text(report.insulinVerified ? "Every confirmed insulin entry matched Glooko at the last check." : "Some insulin entries need review. See the counts below.")
                            .foregroundColor(report.insulinVerified ? .primary : .orange).accessibilityIdentifier("glooko-live-check-result")
                    }
                    if let error = model.data.state.inspectionError {
                        Text("The latest check failed. Any counts shown are from the previous completed check.").foregroundColor(.orange)
                        Text(error).foregroundColor(.red)
                    }
                }
                Section(header: Text("Insulin and queues"), footer: Text("Boluses are sent 10 minutes after they finish and basal hours 15 minutes after the hour ends. Automatic uploads run at 15-minute intervals; Upload now sends immediately.")) {
                    row("Last dose callback", time(model.data.state.lastDoseCallback))
                    row("Latest source dose", time(model.data.latestSourceDose))
                    row("Last settings callback", time(model.data.state.lastSettingsCallback))
                    row("Dose query finished", model.data.doseQueryDrained ? "Yes" : "No")
                    row("Settings query finished", model.data.settingsQueryDrained ? "Yes" : "No")
                    row("Insulin entries waiting", String(model.data.pendingDoses))
                    row("Carbs awaiting confirmation", String(model.data.pendingCarbs))
                    row("Glucose query finished", model.data.glucoseQueryDrained ? "Yes" : "No")
                    row("Glucose awaiting confirmation", String(model.data.pendingGlucose))
                    row("Last glucose callback", time(model.data.state.lastGlucoseCallback))
                    row("Last glucose confirmation", time(model.snapshot.status.lastGlucoseConfirmedAt))
                    row("Last carb confirmation", time(model.snapshot.status.lastCarbConfirmedAt))
                    row("Basal ready through", time(model.snapshot.summary.committedThrough))
                    row("Last insulin sent", time(model.snapshot.status.lastUploadAt))
                    row("Last insulin confirmation", time(model.snapshot.status.lastConfirmedAt))
                    if let report = model.data.state.lastInspection {
                        row("Insulin entries matched", String(report.insulinMatched))
                        row("Missing / different", "\(report.insulinMissing) / \(report.insulinMismatched)")
                        if let glucose = report.glucose {
                            row("Glucose expected", String(glucose.expected))
                            row("Glucose stored / graphed", "\(glucose.matchedStored) / \(glucose.matchedGraphed)")
                            row("Glucose duplicate minutes", String(glucose.duplicates))
                        }
                    }
                    ForEach([model.snapshot.status.lastError, model.snapshot.status.carbError, model.snapshot.status.glucoseError].compactMap { $0 }, id: \.self) { Text($0).foregroundColor(.red) }
                }
                Section(header: Text("Finding data in Glooko")) {
                    Text("Open Daily log for dose and food entries. Glucose sent by Loop uses the LibreView CSV importer and appears as Abbott/CSV data in Glooko.")
                    if let report = model.data.state.lastInspection { ForEach(report.reportWarnings, id: \.self) { Text($0).foregroundColor(.orange) } }
                }
                Section(header: Text("Recent activity"), footer: Text("The last 250 events are retained for up to 48 hours in this account's protected storage. Requests record the route, result, duration and byte counts; headers, query parameters and bodies are excluded.")) {
                    if let error = model.data.storageError { Text(error).foregroundColor(.red) }
                    if model.data.state.events.isEmpty { Text("Activity will appear as Loop receives data or contacts Glooko.").foregroundColor(.secondary) }
                    ForEach(model.data.state.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(time(event.date)) · \(event.category)").font(.caption).foregroundColor(.secondary)
                            Text(event.message).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section(footer: Text("The shared report contains health-data timings, counts and errors. Review it before sharing.")) {
                    Text(build).font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("glooko-diagnostics-done")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { sharedReport = model.export(build: build); showingShare = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }.accessibilityLabel("Share diagnostics").accessibilityIdentifier("glooko-share-diagnostics")
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onReceive(refresh) { _ in model.refresh() }
        .sheet(isPresented: $showingShare) { DiagnosticShareSheet(report: sharedReport ?? "") }
    }
}

private struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let report: String
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [report], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
