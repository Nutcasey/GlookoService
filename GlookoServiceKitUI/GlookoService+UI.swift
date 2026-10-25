import SwiftUI
import Combine
import LoopKit
import LoopKitUI
import GlookoServiceKit

extension GlookoService: ServiceUI {
    public static var image: UIImage? { nil }
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
        let model = SignInModel(email: service?.email ?? "", askForStart: isSetup)
        model.signIn = { [weak self, weak model] email, password, historyStart in
            guard let self else { throw CancellationError() }
            self.signInCancelled = false
            let candidate = self.service ?? GlookoService()
            self.pendingService = candidate
            _ = try await candidate.signIn(email: email, password: password, historyStart: historyStart)
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
        model.delete = { [weak self] in
            guard let self else { return }
            self.service?.completeDelete()
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
    let askForStart: Bool
    var signIn: @MainActor (String, String, Date?) async throws -> Void = { _, _, _ in }
    var cancelled: () -> Void = {}
    private var task: Task<Void, Never>?
    var finished = false

    init(email: String, askForStart: Bool) { self.email = email; self.askForStart = askForStart }

    func submit() {
        guard !busy else { return }
        busy = true; error = nil
        finished = false
        let action = signIn
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        let start = askForStart ? historyStart : nil
        password = ""
        task = Task { [weak self] in
            do { try await action(email, secret, start) }
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
            if model.askForStart {
                Section(footer: Text("For a new account history, choose when the current real pod was activated. Previously saved history for this account resumes from its existing start.")) {
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
    @Published var uploading = false
    @Published var recoveryError: String?
    var signInAgain: () -> Void = {}
    var delete: () -> Void = {}
    var done: () -> Void = {}
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?

    init(service: GlookoService) {
        self.service = service
        snapshot = service.snapshot
        subscription = NotificationCenter.default.publisher(for: GlookoService.stateDidChange, object: service)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
    }
    func refresh() { snapshot = service.snapshot }
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
    @State private var confirmNewPeriod = false
    private func text(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }
    var body: some View {
        Form {
            Section(header: Text("Account")) {
                row("Signed in as", model.snapshot.email ?? "—")
                row("Pump source", model.snapshot.summary.sourceName ?? "Waiting for Loop")
            }
            Section(header: Text("Uploads"), footer: Text("Final history settles for one hour. Loop must finish reading its history before sending. Submission and confirmed Glooko records are tracked separately.")) {
                row("Last submission", text(model.snapshot.status.lastUploadAt))
                row("Last confirmed", text(model.snapshot.status.lastConfirmedAt))
                row("Confirmed through", text(model.snapshot.status.uploadedThrough))
                row("History through", text(model.snapshot.summary.committedThrough))
                row("Waiting to verify", model.snapshot.summary.hasUnuploadedRecords ? "Yes" : "No")
                if let detail = model.snapshot.status.verificationDetail { Text(detail).foregroundColor(.secondary) }
                if let error = model.snapshot.status.lastError { Text(error).foregroundColor(.red).accessibilityIdentifier("glooko-error") }
                Button(model.uploading ? "Uploading…" : "Upload now") { model.uploadNow() }
                    .disabled(model.uploading).accessibilityIdentifier("glooko-upload-now")
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
        .toolbar { Button("Done") { model.done() } }
        .alert("Delete the Glooko service?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Uploads stop. This account's saved history stays on the phone for reconnection. Data already in Glooko stays there.") }
        .alert("Start a new reporting period?", isPresented: $confirmNewPeriod) {
            Button("Archive and start from now", role: .destructive) { model.startNewPeriod() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Unresolved history will be archived for review, not corrected in Glooko. Only delivery from now will enter the new reporting period.") }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title); Spacer(); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
}
