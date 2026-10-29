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
        guard let value else { return "Not yet" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM HH:mm:ss"
        return f.string(from: value)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title); Spacer(); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("Reads back what Glooko has stored and compares it with what Loop sent. It doesn't send or change anything.")) {
                    Button(model.checking || model.data.checking ? "Checking Glooko…" : "Check Glooko now") { model.check() }
                        .disabled(model.checking || model.data.checking).accessibilityIdentifier("glooko-live-check")
                    if let report = model.data.state.lastInspection {
                        row("Last check", time(report.checkedAt))
                        Group {
                            if report.insulinVerified { Label { Text("All insulin sent by Loop matches Glooko.") } icon: { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) } }
                            else { GlookoWarning(text: "Some insulin entries don't match Glooko. See Insulin below.") }
                        }.accessibilityIdentifier("glooko-live-check-result")
                    }
                    if let error = model.data.state.inspectionError {
                        GlookoWarning(text: "The last check failed, so the results below are from the check before it. \(error)")
                    }
                }
                Section(header: Text("Insulin"), footer: Text("Boluses are sent 10 minutes after they finish and basal 15 minutes after each hour ends.")) {
                    row("Latest dose in Loop", time(model.data.latestSourceDose))
                    row("Last received from Loop", time(model.data.state.lastDoseCallback))
                    row("Loop history loaded", model.data.doseQueryDrained ? "Yes" : "No")
                    row("Basal ready through", time(model.snapshot.summary.committedThrough))
                    row("Last sent", time(model.snapshot.status.lastUploadAt))
                    row("Last confirmed", time(model.snapshot.status.lastConfirmedAt))
                    row("Waiting to send", String(model.data.pendingDoses))
                    if let report = model.data.state.lastInspection {
                        row("Matched in Glooko", String(report.insulinMatched))
                        row("Missing in Glooko", String(report.insulinMissing))
                        row("Different in Glooko", String(report.insulinMismatched))
                    }
                    if let error = model.snapshot.status.lastError { GlookoWarning(text: error) }
                }
                Section(header: Text("Glucose")) {
                    row("Last received from Loop", time(model.data.state.lastGlucoseCallback))
                    row("Loop history loaded", model.data.glucoseQueryDrained ? "Yes" : "No")
                    row("Last confirmed", time(model.snapshot.status.lastGlucoseConfirmedAt))
                    row("Waiting to confirm", String(model.data.pendingGlucose))
                    if let glucose = model.data.state.lastInspection?.glucose {
                        row("Expected in Glooko", String(glucose.expected))
                        row("Stored in Glooko", String(glucose.matchedStored))
                        row("Shown on Glooko graphs", String(glucose.matchedGraphed))
                        row("Duplicate minutes", String(glucose.duplicates))
                    }
                    if let error = model.snapshot.status.glucoseError { GlookoWarning(text: error) }
                }
                Section(header: Text("Carbs and settings")) {
                    row("Last carb confirmed", time(model.snapshot.status.lastCarbConfirmedAt))
                    row("Carbs waiting to confirm", String(model.data.pendingCarbs))
                    row("Last settings from Loop", time(model.data.state.lastSettingsCallback))
                    row("Settings history loaded", model.data.settingsQueryDrained ? "Yes" : "No")
                    if let error = model.snapshot.status.carbError { GlookoWarning(text: error) }
                }
                Section(header: Text("Finding data in Glooko")) {
                    Text("Open the Daily log for insulin and food entries. Glucose appears as Abbott/CSV data.")
                    if let report = model.data.state.lastInspection { ForEach(report.reportWarnings, id: \.self) { GlookoWarning(text: $0) } }
                }
                Section(header: Text("Recent activity"), footer: Text("Keeps the last 250 events for up to 48 hours. Requests record only the address, result, time taken and size, never their contents.")) {
                    if let error = model.data.storageError { GlookoWarning(text: error) }
                    if model.data.state.events.isEmpty { Text("Activity will appear as Loop receives data or contacts Glooko.").foregroundColor(.secondary) }
                    ForEach(model.data.state.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(time(event.date)) · \(event.category)").font(.caption).foregroundColor(.secondary)
                            Text(event.message).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section(footer: Text("The shared report includes health-data times, counts and errors. Check it before you share it.")) {
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
