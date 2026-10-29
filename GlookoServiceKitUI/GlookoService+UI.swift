import SwiftUI
import Combine
import LoopKit
import LoopKitUI
import GlookoServiceKit

extension GlookoService: ServiceUI {
    public static var image: UIImage? {
        UIImage(named: "Glooko", in: Bundle(for: GlookoServiceCoordinator.self), compatibleWith: nil)
    }
    public static func setupViewController(colorPalette: LoopUIColorPalette, pluginHost: PluginHost, allowDebugFeatures: Bool) -> SetupUIResult<ServiceViewController, ServiceUI> {
        .userInteractionRequired(GlookoServiceCoordinator(service: nil))
    }
    public func settingsViewController(colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> ServiceViewController { GlookoServiceCoordinator(service: self) }
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
        model.signIn = { [weak self, weak model] email, password, historyStart, remember, insulin, cellular, glucose in
            guard let self else { throw CancellationError() }
            self.signInCancelled = false
            let candidate = self.service ?? GlookoService()
            self.pendingService = candidate
            _ = try await candidate.signIn(email: email, password: password, historyStart: historyStart, rememberPassword: remember, insulinEnabled: insulin, allowCellular: cellular, glucoseEnabled: glucose)
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
    @Published var glucoseEnabled = true
    @Published var allowCellular = false
    let askForStart: Bool
    var signIn: @MainActor (String, String, Date?, Bool, Bool, Bool, Bool) async throws -> Void = { _, _, _, _, _, _, _ in }
    var cancelled: () -> Void = {}
    private var task: Task<Void, Never>?
    var finished = false

    init(email: String, askForStart: Bool, options: GlookoService.Options?) {
        self.email = email; self.askForStart = askForStart
        rememberPassword = options?.rememberPassword ?? false; insulinEnabled = options?.insulinEnabled ?? false
        allowCellular = options?.allowCellular ?? false; glucoseEnabled = options?.glucoseEnabled ?? true
    }

    func submit() {
        guard !busy else { return }
        busy = true; error = nil
        finished = false
        let action = signIn
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        let start = askForStart ? historyStart : nil
        let remember = rememberPassword, insulin = insulinEnabled, cellular = allowCellular, glucose = glucoseEnabled
        password = ""
        task = Task { [weak self] in
            do { try await action(email, secret, start, remember, insulin, cellular, glucose) }
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
            Section(header: Text("Glooko account"), footer: Text("Use the email address and password you sign in to Glooko with.")) {
                TextField("Email", text: $model.email).textContentType(.username).keyboardType(.emailAddress)
                    .autocapitalization(.none).disableAutocorrection(true).disabled(model.busy)
                    .accessibilityIdentifier("glooko-email")
                SecureField("Password", text: $model.password).textContentType(.password).disabled(model.busy)
                    .accessibilityIdentifier("glooko-password")
            }
            Section(footer: Text("Loop normally keeps only your Glooko session, so you sign in again when it expires. If you save the password, it is kept in this iPhone's Keychain and used to sign in again for you.")) {
                Toggle("Save password on this iPhone", isOn: $model.rememberPassword).disabled(model.busy)
                    .accessibilityIdentifier("glooko-remember-password")
            }
            Section(header: Text("What to send"), footer: Text("Carbs are always sent. Insulin appears in Glooko as basal and bolus entries named after your insulin, such as ‘Novolog via Loop’. Glucose appears as Abbott/CSV data, even from a Dexcom. Simulator data is never sent, and nothing in Loop's therapy settings changes.")) {
                Toggle("Insulin", isOn: $model.insulinEnabled).disabled(model.busy).accessibilityIdentifier("glooko-insulin-enabled")
                Toggle("Glucose", isOn: $model.glucoseEnabled).disabled(model.busy).accessibilityIdentifier("glooko-glucose-enabled")
            }
            Section(footer: Text("Without mobile data, Loop waits for Wi-Fi before sending.")) {
                Toggle("Use mobile data", isOn: $model.allowCellular).disabled(model.busy)
            }
            if model.askForStart {
                Section(footer: Text("Loop can send up to 7 days of history. If this account was connected before, sending carries on from where it stopped.")) {
                    DatePicker("Send history from", selection: $model.historyStart, in: Date().addingTimeInterval(-7 * 86400)...Date())
                        .disabled(model.busy).accessibilityIdentifier("glooko-history-start")
                }
            }
            if let error = model.error { Section { GlookoWarning(text: error) } }
            Section {
                Button(model.busy ? "Signing in…" : "Sign in") { model.submit() }
                    .disabled(model.busy || model.email.isEmpty || model.password.isEmpty).accessibilityIdentifier("glooko-sign-in")
                Button("Cancel", role: .cancel) { model.cancel() }
            }
        }
        .onDisappear { model.disappeared() }
    }
}

/// The one style for anything that needs the user's attention, so problems read the same on every screen.
struct GlookoWarning: View {
    let text: String
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red) }
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
    func configure(insulin: Bool? = nil, cellular: Bool? = nil, glucose: Bool? = nil) {
        service.configureUploads(insulin: insulin ?? options.insulinEnabled,
            cellular: cellular ?? options.allowCellular, glucose: glucose ?? options.glucoseEnabled); refresh()
    }
    func forgetPassword() {
        do { try service.stopRememberingPassword(); recoveryError = nil; refresh() }
        catch { recoveryError = "Couldn't forget the saved password: \(error)" }
    }
    func remove(erase: Bool) {
        do { try delete(erase); recoveryError = nil }
        catch { recoveryError = "Couldn't finish deleting the service: \(error)"; refresh() }
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
}

struct StatusView: View {
    @ObservedObject var model: StatusModel
    @State private var confirmDelete = false
    @State private var confirmErase = false
    @State private var showDiagnostics = false
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
        guard let date else { return "Not yet" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB")
        let calendar = Calendar.current
        formatter.dateFormat = calendar.isDateInToday(date) ? "'Today at' HH:mm" : calendar.isDateInYesterday(date) ? "'Yesterday at' HH:mm"
            : calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMMM 'at' HH:mm" : "d MMMM yyyy"
        return formatter.string(from: date)
    }
    private var waiting: Int {
        (model.options.insulinEnabled ? model.snapshot.summary.pendingDoses : 0)
            + (model.options.glucoseEnabled ? model.snapshot.summary.pendingGlucose : 0) + model.snapshot.summary.pendingCarbs
    }
    private var problem: Bool {
        let status = model.snapshot.status
        return (model.options.insulinEnabled && status.lastError != nil) || (model.options.glucoseEnabled && status.glucoseError != nil)
            || status.carbError != nil || status.sourceReplayDetail != nil
    }
    private var health: (title: String, symbol: String, colour: Color) {
        if model.options.authenticationRequired != nil { return ("Sign in needed", "exclamationmark.triangle.fill", .red) }
        if problem { return ("Some data can't be sent", "exclamationmark.triangle.fill", .red) }
        if waiting > 0 { return ("\(waiting) waiting to send", "clock.fill", .secondary) }
        return ("Up to date", "checkmark.circle.fill", .green)
    }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image("Loop", bundle: Bundle(for: GlookoServiceCoordinator.self))
                        .resizable().scaledToFit().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        (Text(Image(systemName: health.symbol)).foregroundColor(health.colour) + Text(" " + health.title))
                            .font(.headline).accessibilityLabel(health.title).accessibilityIdentifier("glooko-health")
                        Text(model.snapshot.email ?? "Not signed in").font(.subheadline).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if let reason = model.options.authenticationRequired {
                    Text(reason).foregroundColor(.secondary)
                    Button("Sign in") { model.signInAgain() }
                }
            }
            Section(header: Text("Insulin"), footer: Text(model.options.insulinEnabled ? "Each bolus is one entry. Basal is sent as the total for each clock hour, 15 minutes after the hour ends; Glooko doesn't receive basal rates, temporary basals or suspensions. Changes made later in Loop update the same entries. Older entries may appear under ‘Insulet Omnipod System’." : "Turn on to send the basal and bolus insulin your pump delivers.")) {
                Toggle("Send insulin", isOn: Binding(get: { model.options.insulinEnabled }, set: { model.configure(insulin: $0) })).accessibilityIdentifier("glooko-insulin-enabled")
                if model.options.insulinEnabled {
                    row("Pump", model.snapshot.summary.sourceName ?? "Waiting for a pump").accessibilityIdentifier("glooko-pump-upload-source")
                    row("Last confirmed", text(model.snapshot.status.lastConfirmedAt))
                    row("Basal sent through", text(model.snapshot.status.uploadedThrough))
                    row("Waiting to send", String(model.snapshot.summary.pendingDoses)).accessibilityIdentifier("glooko-insulin-waiting")
                    row("Entries in Glooko", String(model.snapshot.summary.records)).accessibilityIdentifier("glooko-insulin-confirmed")
                    if let detail = model.snapshot.status.verificationDetail { lastSend(detail).accessibilityIdentifier("glooko-insulin-detail") }
                    if let error = model.snapshot.status.lastError { GlookoWarning(text: error).accessibilityIdentifier("glooko-error") }
                }
            }
            Section(header: Text("Glucose"), footer: Text("Sends readings from the CGM connected to Loop. Turn this off if something else already sends glucose to Glooko. Glooko labels these readings Abbott/CSV and rounds them to the minute.")) {
                Toggle("Send glucose", isOn: Binding(get: { model.options.glucoseEnabled }, set: { model.configure(glucose: $0) }))
                    .accessibilityIdentifier("glooko-glucose-enabled")
                if model.options.glucoseEnabled {
                    row("Last confirmed", text(model.snapshot.status.lastGlucoseConfirmedAt))
                    row("Readings sent through", text(model.snapshot.status.glucoseThrough))
                    row("Waiting to send", String(model.snapshot.summary.pendingGlucose)).accessibilityIdentifier("glooko-glucose-waiting")
                    if let detail = model.snapshot.status.glucoseDetail { lastSend(detail) }
                    if let error = model.snapshot.status.glucoseError { GlookoWarning(text: error) }
                }
            }
            Section(header: Text("Carbs"), footer: Text("Carbs are always sent, soon after you save them. Edits and deletions update the same Glooko food entry. Find them in Glooko's graphs and history; the Diet panel may stay empty.")) {
                row("Last confirmed", text(model.snapshot.status.lastCarbConfirmedAt))
                row("Waiting to send", String(model.snapshot.summary.pendingCarbs))
                if let detail = model.snapshot.status.carbDetail { lastSend(detail) }
                if let error = model.snapshot.status.carbError { GlookoWarning(text: error) }
                if let detail = model.snapshot.status.sourceReplayDetail { GlookoWarning(text: detail) }
            }
            Section(header: Text("Sending"), footer: Text("Loop sends new data every 15 minutes. Without mobile data, sending waits for Wi-Fi. You'll get an alert if data has been waiting longer than the time you choose.")) {
                Button(model.uploading ? "Sending…" : "Send now") { model.uploadNow() }
                    .disabled(model.uploading).accessibilityIdentifier("glooko-upload-now")
                Toggle("Use mobile data", isOn: Binding(get: { model.options.allowCellular }, set: { model.configure(cellular: $0) }))
                Picker("Alert after", selection: Binding(get: { model.options.alertThreshold }, set: { model.service.setAlertThreshold($0); model.refresh() })) {
                    Text("30 minutes").tag(TimeInterval(1800)); Text("1 hour").tag(TimeInterval(3600))
                    Text("2 hours").tag(TimeInterval(7200)); Text("4 hours").tag(TimeInterval(14400))
                }
                Button("Send a test alert") { model.service.sendTestAlert() }.accessibilityIdentifier("glooko-test-alert")
            }
            Section(header: Text("Account")) {
                row("Sending history from", text(model.snapshot.summary.historyStart))
                row("Password", model.options.rememberPassword ? "Saved on this iPhone" : "Not saved")
                if model.options.rememberPassword { Button("Forget saved password") { model.forgetPassword() } }
                Button("Change account or sign-in options") { model.signInAgain() }
            }
            Section(header: Text("Help")) {
                Button { showDiagnostics = true } label: {
                    Label("Diagnostics and Glooko check", systemImage: "stethoscope")
                }.accessibilityIdentifier("glooko-diagnostics")
                row("Build", Self.build).font(.footnote).accessibilityIdentifier("glooko-build")
            }
            if let error = model.recoveryError { Section { GlookoWarning(text: error) } }
            Section {
                Button("Delete Glooko service", role: .destructive) { confirmDelete = true }
            }
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(service: model.service, build: Self.build) }
        .toolbar { Button("Done") { model.done() } }
        .alert("Delete the Glooko service?", isPresented: $confirmDelete) {
            Button("Delete and keep local history", role: .destructive) { model.remove(erase: false) }
            Button("Delete and erase local data", role: .destructive) { confirmErase = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Keeping local history lets you reconnect later without sending everything again. Data already in Glooko isn't affected either way.") }
        .alert("Erase all local Glooko data?", isPresented: $confirmErase) {
            Button("Delete and erase local data", role: .destructive) { model.remove(erase: true) }
                .accessibilityIdentifier("glooko-erase-local-data")
            Button("Cancel", role: .cancel) {}
        } message: { Text("This erases Loop's record of what was sent, its diagnostics and your saved Glooko sign-in. It can't be undone. Data in Glooko and in Loop isn't affected.") }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title); Spacer(); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
    /// Service details describe the most recent batch, not the totals shown in the rows above them.
    private func lastSend(_ detail: String) -> some View { Text("Last send: " + detail).font(.footnote).foregroundColor(.secondary) }
}
