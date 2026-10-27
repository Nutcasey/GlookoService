import SwiftUI
import Combine
import LoopKit
import LoopKitUI
import GlookoServiceKit

extension GlookoService: ServiceUI {
    public static var image: UIImage? {
        UIImage(named: "Glooko", in: Bundle(for: GlookoServiceCoordinator.self), compatibleWith: nil)
    }
    public static func setupViewController(colorPalette: LoopUIColorPalette, pluginHost: PluginHost) -> SetupUIResult<ServiceViewController, ServiceUI> {
        .userInteractionRequired(GlookoServiceCoordinator(service: nil))
    }
    public func settingsViewController(colorPalette: LoopUIColorPalette) -> ServiceViewController { GlookoServiceCoordinator(service: self) }
}

final class GlookoServiceCoordinator: UINavigationController, ServiceOnboarding, CompletionNotifying {
    weak var serviceOnboardingDelegate: ServiceOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?
    private var service: GlookoService?
    private var pendingService: GlookoService?
    private var signInCancelled = false

    init(service: GlookoService?) {
        self.service = service
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        setViewControllers([service?.isOnboarded == true ? statusController() : signInController(isSetup: true)], animated: false)
    }

    private func signInController(isSetup: Bool) -> UIViewController {
        let model = SignInModel(email: service?.email ?? "", askForStart: isSetup, options: service?.options)
        model.signIn = { [weak self, weak model] email, password, historyStart, remember, insulin, glucose, cellular in
            guard let self else { throw CancellationError() }
            self.signInCancelled = false
            let candidate = self.service ?? GlookoService()
            self.pendingService = candidate
            _ = try await candidate.signIn(email: email, password: password, historyStart: historyStart, rememberPassword: remember, insulinEnabled: insulin, glucoseEnabled: glucose, allowCellular: cellular)
            try Task.checkCancellation()
            guard !self.signInCancelled else { throw CancellationError() }
            model?.finished = true
            self.pendingService = nil
            if self.service == nil {
                self.service = candidate
                self.serviceOnboardingDelegate?.serviceOnboarding(didCreateService: candidate)
                self.serviceOnboardingDelegate?.serviceOnboarding(didOnboardService: candidate)
                self.completionDelegate?.completionNotifyingDidComplete(self)
            } else { self.setViewControllers([self.statusController()], animated: true) }
        }
        model.cancelled = { [weak self] in
            guard let self else { return }
            self.signInCancelled = true
            self.pendingService?.cancelSignIn()
            if self.service == nil { self.pendingService?.completeDelete() }
            self.pendingService = nil
            if isSetup { self.completionDelegate?.completionNotifyingDidComplete(self) }
            else { self.setViewControllers([self.statusController()], animated: true) }
        }
        let controller = UIHostingController(rootView: SignInView(model: model))
        controller.title = "Glooko"
        return controller
    }

    private func statusController() -> UIViewController {
        let model = StatusModel(service: service!)
        model.signInAgain = { [weak self] in
            guard let self else { return }
            self.setViewControllers([self.signInController(isSetup: false)], animated: true)
        }
        model.delete = { [weak self] erase in
            guard let self else { return }
            try self.service?.removeService(eraseLocalData: erase)
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        model.done = { [weak self] in
            guard let self else { return }
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        let controller = UIHostingController(rootView: StatusView(model: model))
        controller.title = "Glooko"
        return controller
    }
}

@MainActor final class SignInModel: ObservableObject {
    @Published var email: String
    @Published var password = ""
    @Published var busy = false
    @Published var error: String?
    @Published var historyStart = Date()
    @Published var rememberPassword = false
    @Published var insulinEnabled = false
    @Published var glucoseEnabled = false
    @Published var allowCellular = false
    let askForStart: Bool
    var signIn: @MainActor (String, String, Date?, Bool, Bool, Bool, Bool) async throws -> Void = { _, _, _, _, _, _, _ in }
    var cancelled: () -> Void = {}
    private var task: Task<Void, Never>?
    var finished = false

    init(email: String, askForStart: Bool, options: GlookoService.Options?) {
        self.email = email; self.askForStart = askForStart
        rememberPassword = options?.rememberPassword ?? false; insulinEnabled = options?.insulinEnabled ?? false
        glucoseEnabled = options?.glucoseEnabled ?? false; allowCellular = options?.allowCellular ?? false
    }

    func submit() {
        guard !busy else { return }
        busy = true; error = nil
        finished = false
        let action = signIn
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        let start = askForStart ? historyStart : nil
        let remember = rememberPassword, insulin = insulinEnabled, glucose = glucoseEnabled, cellular = allowCellular
        password = ""
        task = Task { [weak self] in
            do { try await action(email, secret, start, remember, insulin, glucose, cellular) }
            catch { if !Task.isCancelled { self?.error = String(describing: error) } }
            self?.busy = false
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel(); task = nil; password = ""; busy = false
        cancelled()
    }
    func disappeared() {
        password = ""
        if busy && !finished { cancel() }
    }
}

struct SignInView: View {
    @ObservedObject var model: SignInModel
    var body: some View {
        Form {
            Section(footer: Text("Loop sends verified pump history to this account as a virtual Omnipod reporting device. Pump Simulator data is excluded. No therapy is changed.")) {
                TextField("E-mail", text: $model.email).textContentType(.username).keyboardType(.emailAddress)
                    .autocapitalization(.none).disableAutocorrection(true).disabled(model.busy)
                    .accessibilityIdentifier("glooko-email")
                SecureField("Password", text: $model.password).textContentType(.password).disabled(model.busy)
                    .accessibilityIdentifier("glooko-password")
            }
            Section(footer: Text("By default only the session is saved. If you enable password recovery, the password is retrievable by this app from this device's Keychain and may be sent again when the session expires. Glooko OAuth requires a separately registered application.")) {
                Toggle("Remember password for session recovery", isOn: $model.rememberPassword).disabled(model.busy)
                    .accessibilityIdentifier("glooko-remember-password")
            }
            Section(header: Text("Compatibility upload routes"), footer: Text("These are manufacturer-specific compatibility formats, not a native Loop integration. Insulin is presented to Glooko as an Insulet Omnipod PDM; glucose as Abbott LibreView CSV. Carb food entries do not require either device identity. Enable only the routes you accept.")) {
                Toggle("Insulin via virtual Omnipod format", isOn: $model.insulinEnabled).disabled(model.busy)
                Toggle("Glucose via LibreView CSV", isOn: $model.glucoseEnabled).disabled(model.busy)
                Toggle("Allow cellular data", isOn: $model.allowCellular).disabled(model.busy)
            }
            if model.askForStart {
                Section(footer: Text("Choose when reporting should begin within the history Loop can supply. Previously saved history for this account resumes from its existing start.")) {
                    DatePicker("Send history from", selection: $model.historyStart, in: Date().addingTimeInterval(-7 * 86400)...Date())
                        .disabled(model.busy).accessibilityIdentifier("glooko-history-start")
                }
            }
            if let error = model.error { Section { Text(error).foregroundColor(.red) } }
            Section {
                Button(model.busy ? "Signing in…" : "Sign in") { model.submit() }
                    .disabled(model.busy || model.email.isEmpty || model.password.isEmpty).accessibilityIdentifier("glooko-sign-in")
                Button("Cancel", role: .cancel) { model.cancel() }
            }
        }
        .onDisappear { model.disappeared() }
    }
}

@MainActor final class StatusModel: ObservableObject {
    let service: GlookoService
    @Published var snapshot: GlookoService.Snapshot
    @Published var options: GlookoService.Options
    @Published var uploading = false
    @Published var recoveryError: String?
    var signInAgain: () -> Void = {}
    var delete: (Bool) throws -> Void = { _ in }
    var done: () -> Void = {}
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?

    init(service: GlookoService) {
        self.service = service
        snapshot = service.snapshot; options = service.options
        subscription = NotificationCenter.default.publisher(for: GlookoService.stateDidChange, object: service)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
    }
    func refresh() { snapshot = service.snapshot; options = service.options }
    func configure(insulin: Bool? = nil, glucose: Bool? = nil, cellular: Bool? = nil) {
        service.configureUploads(insulin: insulin ?? options.insulinEnabled, glucose: glucose ?? options.glucoseEnabled,
            cellular: cellular ?? options.allowCellular); refresh()
    }
    func forgetPassword() {
        do { try service.stopRememberingPassword(); recoveryError = nil; refresh() }
        catch { recoveryError = "Could not remove the stored password: \(error)" }
    }
    func remove(erase: Bool) {
        do { try delete(erase); recoveryError = nil }
        catch { recoveryError = "Could not finish removing the service: \(error)"; refresh() }
    }
    func uploadNow() {
        guard !uploading else { return }
        uploading = true
        let service = service
        task = Task { [weak self] in
            await service.uploadIfNeeded(force: true)
            self?.refresh(); self?.uploading = false; self?.task = nil
        }
    }
    func startNewPeriod() {
        do { try service.startNewReportingPeriod(); recoveryError = nil; refresh() }
        catch { recoveryError = String(describing: error) }
    }
}

struct StatusView: View {
    @ObservedObject var model: StatusModel
    @State private var confirmDelete = false
    @State private var confirmErase = false
    @State private var showDiagnostics = false
    @State private var confirmNewPeriod = false
    private static let build: String = {
        let bundle = Bundle(for: GlookoServiceCoordinator.self)
        guard let url = bundle.url(forResource: "GlookoBuild", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let details = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let commit = details["commit"] as? String,
              let dirty = details["dirty"] as? Bool,
              let date = details["date"] as? Date else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy 'at' HH:mm:ss z"
        return commit + (dirty ? ".dirty" : "") + "\n" + formatter.string(from: date)
    }()
    private func text(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }
    var body: some View {
        Form {
            Section(header: Text("Upload source"), footer: Text("Glooko's website may still display ‘Insulet Omnipod System’. The Loop source label is saved and verified separately.")) {
                HStack(spacing: 12) {
                    Image("Loop", bundle: Bundle(for: GlookoServiceCoordinator.self))
                        .resizable().scaledToFit().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.snapshot.summary.pumpUploadName ?? "Waiting for a real pump")
                            .font(.headline).accessibilityIdentifier("glooko-pump-upload-source")
                        Text(model.options.insulinEnabled ? "Insulin uploaded by Loop" : "Insulin uploads disabled").font(.subheadline).foregroundColor(.secondary)
                    }
                }
                row("Saved in Glooko", model.snapshot.status.pumpSourceLabel ?? "Waiting to verify")
                    .accessibilityIdentifier("glooko-pump-source-label")
                row("Label verified", text(model.snapshot.status.pumpSourceLabelVerifiedAt))
                if let error = model.snapshot.status.pumpSourceLabelError {
                    Text(error).foregroundColor(.orange).accessibilityIdentifier("glooko-pump-source-error")
                }
            }
            Section(header: Text("Account")) {
                row("Signed in as", model.snapshot.email ?? "—")
                row("Build", Self.build).accessibilityIdentifier("glooko-build")
                Button { showDiagnostics = true } label: {
                    Label("Diagnostics and live check", systemImage: "list.bullet.rectangle")
                }.accessibilityIdentifier("glooko-diagnostics")
            }
            Section(header: Text("Authentication and alerts")) {
                row("Password recovery", model.options.rememberPassword ? "Enabled on this device" : "Sign in when the session expires")
                if let reason = model.options.authenticationRequired { Text(reason).foregroundColor(.red) }
                if model.options.rememberPassword { Button("Forget stored password") { model.forgetPassword() } }
                Button("Change sign-in settings") { model.signInAgain() }
                Button("Send test alert") { model.service.sendTestAlert() }.accessibilityIdentifier("glooko-test-alert")
                Picker("Alert when eligible data waits", selection: Binding(get: { model.options.alertThreshold }, set: { model.service.setAlertThreshold($0); model.refresh() })) {
                    Text("30 minutes").tag(TimeInterval(1800)); Text("1 hour").tag(TimeInterval(3600))
                    Text("2 hours").tag(TimeInterval(7200)); Text("4 hours").tag(TimeInterval(14400))
                }
            }
            Section(header: Text("Compatibility upload routes"), footer: Text("Glooko identifies these as Insulet Omnipod and Abbott LibreView CSV, not as a native Loop device. Local queued history is retained when a route is disabled. Carb food uploads are independent. Wi-Fi-only requests may wait until Wi-Fi is available.")) {
                Toggle("Insulin via virtual Omnipod format", isOn: Binding(get: { model.options.insulinEnabled }, set: { model.configure(insulin: $0) }))
                Toggle("Glucose via LibreView CSV", isOn: Binding(get: { model.options.glucoseEnabled }, set: { model.configure(glucose: $0) }))
                Toggle("Allow cellular data", isOn: Binding(get: { model.options.allowCellular }, set: { model.configure(cellular: $0) }))
            }
            Section(header: Text("Uploads"), footer: Text("Final history settles for one hour. Loop must finish reading its history before sending. Submission and confirmed Glooko records are tracked separately.")) {
                row("Last submission", text(model.snapshot.status.lastUploadAt))
                row("Last confirmed", text(model.snapshot.status.lastConfirmedAt))
                row("Confirmed through", text(model.snapshot.status.uploadedThrough))
                row("History through", text(model.snapshot.summary.committedThrough))
                row("Waiting to verify", model.snapshot.summary.hasUnuploadedRecords ? "Yes" : "No")
                if model.snapshot.summary.correctedBasalIntervals > 0 {
                    row("Corrected basal intervals", String(model.snapshot.summary.correctedBasalIntervals))
                }
                if let detail = model.snapshot.status.verificationDetail { Text(detail).foregroundColor(.secondary) }
                if let error = model.snapshot.status.lastError { Text(error).foregroundColor(.red).accessibilityIdentifier("glooko-error") }
                Button(model.uploading ? "Uploading…" : "Upload now") { model.uploadNow() }
                    .disabled(model.uploading).accessibilityIdentifier("glooko-upload-now")
            }
            Section(header: Text("Carbs"), footer: Text("Carbs entered in Loop are sent as Glooko food entries soon after you save them. Edits and deletions update the same entry.")) {
                row("Last confirmed", text(model.snapshot.status.lastCarbConfirmedAt))
                row("Waiting to send", String(model.snapshot.summary.pendingCarbs))
                if let detail = model.snapshot.status.carbDetail { Text(detail).foregroundColor(.secondary) }
                if let error = model.snapshot.status.carbError { Text(error).foregroundColor(.red) }
                Text("Find carb-only food entries in Glooko Graphs and History. Its Diet panel may remain empty for these entries.").foregroundColor(.secondary)
            }
            Section(header: Text("Glucose"), footer: Text("Numeric Dexcom G7 readings from Loop are sent through Glooko's CSV importer. Glooko lists this as a LibreView CSV reporting source, with minute-resolution timestamps. Original sensor timestamps stay on this phone. History comes only from the glucose stream Loop supplies. Existing matching readings are not uploaded twice.")) {
                row("Last confirmed", text(model.snapshot.status.lastGlucoseConfirmedAt))
                row("Confirmed through minute", text(model.snapshot.status.glucoseThrough))
                row("Waiting to send", String(model.snapshot.summary.pendingGlucose))
                if let detail = model.snapshot.status.glucoseBackfillDetail { Text(detail).foregroundColor(.secondary) }
                if let error = model.snapshot.status.glucoseBackfillError { Text(error).foregroundColor(.red) }
                if let detail = model.snapshot.status.glucoseDetail { Text(detail).foregroundColor(.secondary) }
                if let error = model.snapshot.status.glucoseError { Text(error).foregroundColor(.red) }
            }
            Section(header: Text("Glooko reports"), footer: Text("Device-record confirmation and Glooko's Summary are checked separately. Report differences do not change the source insulin quantities. Automatic bolus labels are preserved in Loop history; the current Glooko pump-file format cannot carry them.")) {
                row("Last checked", text(model.snapshot.status.lastReportCheckedAt))
                ForEach(model.snapshot.status.reportWarnings, id: \.self) { Text($0).foregroundColor(.orange) }
                if let error = model.snapshot.status.reportError { Text(error).foregroundColor(.red) }
            }
            Section(header: Text("History")) {
                row("History from", text(model.snapshot.summary.historyStart))
                row("PDM serial", String(model.snapshot.summary.serial))
                row("Records", String(model.snapshot.summary.records))
                row("Doses awaiting finalisation", String(model.snapshot.summary.pendingDoses))
                if model.snapshot.summary.lateDoses > 0 { row("Distinct late doses", String(model.snapshot.summary.lateDoses)) }
                if model.snapshot.summary.conflictCount > 0 { row("Changes needing review", String(model.snapshot.summary.conflictCount)) }
            }
            if model.snapshot.summary.canStartNewPeriod && model.snapshot.status.lastError != nil {
                Section(footer: Text("Reconnect to the pump first if a dose is still provisional. If the source changed or old records cannot be corrected, you can archive the saved history and continue from now. The archive remains on this phone; existing Glooko records are unchanged.")) {
                    Button("Start a new reporting period") { confirmNewPeriod = true }
                }
            }
            if let error = model.recoveryError { Text(error).foregroundColor(.red) }
            Section {
                Button("Sign in again") { model.signInAgain() }
                Button("Delete Glooko service", role: .destructive) { confirmDelete = true }
            }
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(service: model.service, build: Self.build) }
        .toolbar { Button("Done") { model.done() } }
        .alert("Delete the Glooko service?", isPresented: $confirmDelete) {
            Button("Disconnect and keep history", role: .destructive) { model.remove(erase: false) }
            Button("Erase local data and remove", role: .destructive) { confirmErase = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Choose whether to keep this service's local history for reconnection or erase all locally saved Glooko history, archives and diagnostics. Data already in Glooko is unchanged.") }
        .alert("Erase all local Glooko data?", isPresented: $confirmErase) {
            Button("Erase local data and remove", role: .destructive) { model.remove(erase: true) }
                .accessibilityIdentifier("glooko-erase-local-data")
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes all locally saved Glooko pump, glucose and carb history, archives, legacy backups, diagnostics and stored credentials from this app. It cannot be undone. Glooko's remote records and Loop's original source history are unchanged.") }
        .alert("Start a new reporting period?", isPresented: $confirmNewPeriod) {
            Button("Archive and start from now", role: .destructive) { model.startNewPeriod() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Unresolved history will be archived for review, not corrected in Glooko. Only delivery from now will enter the new reporting period.") }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title); Spacer(); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
}
