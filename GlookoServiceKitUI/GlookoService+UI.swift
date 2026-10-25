import SwiftUI
import LoopKit
import LoopKitUI
import GlookoServiceKit

extension GlookoService: ServiceUI {
    public static var image: UIImage? { nil }

    public static func setupViewController(colorPalette: LoopUIColorPalette, pluginHost: PluginHost) -> SetupUIResult<ServiceViewController, ServiceUI> {
        .userInteractionRequired(GlookoServiceCoordinator(service: nil))
    }

    public func settingsViewController(colorPalette: LoopUIColorPalette) -> ServiceViewController {
        GlookoServiceCoordinator(service: self)
    }
}

final class GlookoServiceCoordinator: UINavigationController, ServiceOnboarding, CompletionNotifying {
    weak var serviceOnboardingDelegate: ServiceOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?
    private var service: GlookoService?

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
        model.signIn = { [weak self] email, password in
            guard let self else { return }
            let service = self.service ?? GlookoService()
            _ = try await service.signIn(email: email, password: password, historyStart: isSetup ? model.historyStart : nil)
            await MainActor.run {
                if self.service == nil {
                    self.service = service
                    self.serviceOnboardingDelegate?.serviceOnboarding(didCreateService: service)
                    self.serviceOnboardingDelegate?.serviceOnboarding(didOnboardService: service)
                    self.completionDelegate?.completionNotifyingDidComplete(self)
                } else {
                    self.setViewControllers([self.statusController()], animated: true)
                }
            }
        }
        model.cancel = { [weak self] in
            guard let self else { return }
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

final class SignInModel: ObservableObject {
    @Published var email: String
    @Published var password = ""
    @Published var busy = false
    @Published var error: String?
    /// Defaults to now: earlier delivery in Loop's stores may be simulator or another pump's.
    @Published var historyStart = Date()
    let askForStart: Bool
    var signIn: (String, String) async throws -> Void = { _, _ in }
    var cancel: () -> Void = {}

    init(email: String, askForStart: Bool) { self.email = email; self.askForStart = askForStart }

    @MainActor func submit() async {
        busy = true
        error = nil
        do { try await signIn(email.trimmingCharacters(in: .whitespaces), password) }
        catch { self.error = String(describing: error) }
        busy = false
    }
}

struct SignInView: View {
    @ObservedObject var model: SignInModel

    var body: some View {
        Form {
            Section(footer: Text("Loop sends its pump insulin history (basal, temporary basal, suspensions and boluses) to this Glooko account as an Omnipod PDM upload. It never changes therapy.")) {
                TextField("E-mail", text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("glooko-email")
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .accessibilityIdentifier("glooko-password")
            }
            if model.askForStart {
                Section(footer: Text("Only insulin delivered from this time is sent. Choose when your current pod was activated (Omnipod settings → Activation) to include it; never include Pump Simulator time.")) {
                    DatePicker("Send history from", selection: $model.historyStart,
                               in: Date().addingTimeInterval(-7 * 86400)...Date())
                        .accessibilityIdentifier("glooko-history-start")
                }
            }
            if let error = model.error {
                Section { Text(error).foregroundColor(.red) }
            }
            Section {
                Button(model.busy ? "Signing in…" : "Sign in") { Task { await model.submit() } }
                    .disabled(model.busy || model.email.isEmpty || model.password.isEmpty)
                    .accessibilityIdentifier("glooko-sign-in")
                Button("Cancel", role: .cancel) { model.cancel() }
            }
        }
    }
}

final class StatusModel: ObservableObject {
    let service: GlookoService
    @Published var summary: GlookoService.Summary
    @Published var status: GlookoService.Status
    @Published var uploading = false
    var signInAgain: () -> Void = {}
    var delete: () -> Void = {}
    var done: () -> Void = {}

    init(service: GlookoService) {
        self.service = service
        summary = service.summary
        status = service.status
    }

    func refresh() {
        summary = service.summary
        status = service.status
    }

    @MainActor func uploadNow() async {
        uploading = true
        await service.uploadIfNeeded(force: true)
        refresh()
        uploading = false
    }
}

struct StatusView: View {
    @ObservedObject var model: StatusModel
    @State private var confirmDelete = false

    private func text(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    var body: some View {
        Form {
            Section(header: Text("Account")) {
                row("Signed in as", model.service.email ?? "—")
            }
            Section(header: Text("Uploads"), footer: Text("History is committed once Loop has finished changing it (about an hour) and uploaded at most every 15 minutes. Glooko adds each day's totals once that day is complete.")) {
                row("Last upload", text(model.status.lastUploadAt))
                row("History through", text(model.summary.committedThrough))
                row("Waiting to upload", model.summary.hasUnuploadedRecords ? "Yes" : "No")
                if let error = model.status.lastError {
                    Text(error).foregroundColor(.red).accessibilityIdentifier("glooko-error")
                }
                Button(model.uploading ? "Uploading…" : "Upload now") { Task { await model.uploadNow() } }
                    .disabled(model.uploading)
                    .accessibilityIdentifier("glooko-upload-now")
            }
            Section(header: Text("History")) {
                row("History from", text(model.summary.historyStart))
                row("PDM serial", String(model.summary.serial))
                row("Records", String(model.summary.records))
                row("Doses not yet final", String(model.summary.pendingDoses))
                if model.summary.lateDoses > 0 {
                    row("Doses that arrived too late", String(model.summary.lateDoses))
                }
            }
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
        } message: {
            Text("Uploads stop. Data already in Glooko stays there.")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary) }
    }
}
