import AppKit
import Combine
import ServiceManagement
import UsageCore

enum PanelPreviewScenario: String, CaseIterable {
    case loading, ready, refreshFailed = "refresh-failed", refreshFailedEmpty = "refresh-failed-empty"
    case retrying, retryingEmpty = "retrying-empty", codexMissing = "codex-missing", signInRequired = "sign-in-required"
    case expired
    case noResets = "no-resets", resetConfirm = "reset-confirm", resetProcessing = "reset-processing"
    case resetError = "reset-error", resetSuccess = "reset-success"
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var failure: PanelFailure?
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var now = Date()
    @Published var showSettings = false {
        didSet { if !isDemo { preferences.set(showSettings, forKey: "showSettings") } }
    }
    @Published var showAvailableResets = false {
        didSet {
            if !isDemo { preferences.set(showAvailableResets, forKey: "showAvailableResets") }
            if !showAvailableResets { resetInteraction.dismissTransient() }
        }
    }
    @Published var resetInteraction: ResetInteraction
    @Published var menuBarDisplay: MenuBarDisplay
    @Published var customPath: String
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var onChange: (() -> Void)?
    private let client: any CodexUsageService
    private let preferences: UserDefaults
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var panelIsOpen = false
    private var lastAttempt: Date?
    let isDemo: Bool

    init(demo: Bool = false, preview: PanelPreviewScenario? = nil, expanded: Bool = false,
         client: any CodexUsageService = CodexClient(), preferences: UserDefaults = .standard) {
        self.client = client
        self.preferences = preferences
        isDemo = demo || preview != nil
        resetInteraction = ResetInteraction(retryKeys: isDemo ? [:] : preferences.dictionary(forKey: "resetRetryKeys") as? [String: String] ?? [:])
        menuBarDisplay = MenuBarDisplay(rawValue: preferences.string(forKey: "menuBarDisplay") ?? "") ?? .both
        customPath = preferences.string(forKey: "codexPath") ?? ""
        showSettings = isDemo ? expanded : preferences.bool(forKey: "showSettings")
        showAvailableResets = isDemo ? expanded : preferences.bool(forKey: "showAvailableResets")
        if isDemo {
            configurePreview(preview ?? .ready)
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    var hasPanelData: Bool { snapshot?.panelBucket?.windows.isEmpty == false }

    var isStale: Bool {
        guard let lastUpdated else { return true }
        return failure != nil || now.timeIntervalSince(lastUpdated) > 150
    }

    var phase: PanelPhase {
        PanelPhase(hasData: hasPanelData, isRefreshing: isRefreshing, isStale: isStale, failure: failure)
    }

    var planTitle: String? { snapshot?.panelBucket?.planType?.capitalized }
    var quotas: [PanelQuota] { snapshot?.panelQuotas ?? UsageSnapshot.emptyPanelQuotas }
    var resetSummary: ResetCreditsSummary? { snapshot?.rateLimitResetCredits }
    var resetCount: Int? { resetSummary.map(\.count).flatMap { $0 > 0 ? $0 : nil } }
    var resetCredits: [ResetCredit] {
        guard resetSummary?.count != 0 else { return [] }
        return resetSummary?.credits?.filter { $0.status == "available" || $0.id == resetInteraction.processing?.creditID } ?? []
    }
    var hasPendingReset: Bool { resetTask != nil || resetInteraction.processing != nil }

    func canUseReset(_ credit: ResetCredit) -> Bool {
        !hasPendingReset && !isStale && credit.isUsable(at: now)
            && !resetInteraction.consumedIDs.contains(credit.id)
    }

    func panelDidOpen() { panelIsOpen = true }

    func panelDidClose() {
        panelIsOpen = false
        resetInteraction.dismissTransient()
    }

    func activateReset(_ credit: ResetCredit) {
        guard canUseReset(credit) else { return }
        guard resetInteraction.confirmationID == credit.id else {
            resetInteraction.select(credit.id)
            return
        }
        guard let attempt = resetInteraction.begin(credit.id) else { return }
        saveResetKeys()
        let path = executablePath
        let account = snapshot?.accountId
        resetTask = Task {
            // Finish an earlier read first; a read failure must not interrupt a submitted reset.
            await refreshTask?.value
            var outcome: ResetOutcome?
            if isDemo {
                try? await Task.sleep(nanoseconds: 900_000_000)
                let expanded = showAvailableResets
                configurePreview(.resetSuccess)
                showAvailableResets = expanded
                outcome = .reset
            } else if let path, path == executablePath, account == snapshot?.accountId,
                      !isStale, resetCredits.contains(where: { $0.id == credit.id && $0.isUsable(at: now) }) {
                do { outcome = try await client.consumeReset(executablePath: path, creditID: credit.id,
                                                             idempotencyKey: attempt.idempotencyKey) }
                catch { /* Unknown outcome: preserve the key and reconcile with a fresh read. */ }
            }
            resetInteraction.finish(attempt, outcome: outcome, showError: panelIsOpen && showAvailableResets)
            saveResetKeys()
            if !isDemo { await fetchUsage() }
            resetTask = nil
            onChange?()
        }
    }

    private func saveResetKeys() {
        if !isDemo { preferences.set(resetInteraction.retryKeys, forKey: "resetRetryKeys") }
    }

    var indicator: MenuBarIndicator {
        MenuBarIndicator(snapshot: snapshot, display: menuBarDisplay, isStale: isStale, now: now)
    }

    func setMenuBarDisplay(_ display: MenuBarDisplay) {
        menuBarDisplay = display
        if !isDemo { preferences.set(display.rawValue, forKey: "menuBarDisplay") }
        onChange?()
    }

    var executablePath: String? { CodexExecutable.locate(customPath: customPath) }

    var displayedExecutablePath: String {
        isDemo ? "/usr/local/bin/codex" : executablePath ?? (customPath.isEmpty ? "Not found" : customPath)
    }

    private func tick() {
        now = Date()
        onChange?()
        let elapsed = lastAttempt.map { now.timeIntervalSince($0) } ?? .infinity
        if elapsed >= 60 || (snapshot?.remainingPercent(at: now) == nil && elapsed >= 15) { refresh() }
    }

    func refresh() {
        guard !isRefreshing, !hasPendingReset else { return }
        if isDemo {
            isRefreshing = true
            refreshTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                configurePreview(.ready)
                onChange?()
            }
            return
        }
        isRefreshing = true
        refreshTask = Task { await fetchUsage() }
    }

    private func fetchUsage() async {
        lastAttempt = Date()
        defer { isRefreshing = false; onChange?() }
        guard let path = executablePath else {
            failure = .codexMissing
            errorMessage = CodexError.missingExecutable.localizedDescription
            onChange?()
            return
        }
        // Retry setup as a fresh load, preserving ordinary failures until recovery.
        if failure == .codexMissing || failure == .signInRequired { failure = nil; errorMessage = nil }
        isRefreshing = true
        do {
            let next = try await client.readLimits(executablePath: path)
            guard path == executablePath else { return }
            guard next.panelBucket?.windows.isEmpty == false else {
                failure = .refresh
                errorMessage = "Codex returned no usage limits for this account."
                return
            }
            snapshot = next
            resetInteraction.reconcile(next.rateLimitResetCredits)
            lastUpdated = Date()
            now = Date()
            failure = nil
            errorMessage = nil
        } catch {
            failure = PanelFailure(error: error)
            errorMessage = error.localizedDescription
        }
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Locate Codex"
        panel.message = "Choose the codex executable installed by Homebrew, npm, or the Codex app."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            if !isDemo { preferences.set(customPath, forKey: "codexPath") }
            refresh()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if isDemo { launchAtLogin = enabled; return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change launch at login"
            alert.runModal()
        }
    }

    func shutdown() async {
        timer?.invalidate()
        // Let an explicitly confirmed reset settle before shutting down its transport.
        await resetTask?.value
        refreshTask?.cancel()
        await client.shutdown()
    }

    func configurePreview(_ scenario: PanelPreviewScenario) {
        menuBarDisplay = .fiveHour
        launchAtLogin = true
        failure = nil
        errorMessage = nil
        isRefreshing = false
        snapshot = nil
        lastUpdated = nil
        now = Date()
        resetInteraction = ResetInteraction()
        if [.ready, .refreshFailed, .retrying, .expired, .noResets, .resetConfirm, .resetProcessing, .resetError, .resetSuccess].contains(scenario) {
            let firstReset = now.addingTimeInterval(scenario == .expired ? -10 : 8460).timeIntervalSince1970
            let secondReset = now.addingTimeInterval(576000).timeIntervalSince1970
            let used = scenario == .resetSuccess ? 0 : 50
            let count = scenario == .noResets ? 0 : scenario == .resetSuccess ? 1 : 2
            let resetDate = now.addingTimeInterval(30 * 86400).timeIntervalSince1970
            let credit1 = """
            {"id":"preview-1","resetType":"codexRateLimits","status":"available","grantedAt":0,"expiresAt":\(resetDate),"title":"Full reset (Weekly + 5 hr)"}
            """
            let credit2 = """
            {"id":"preview-2","resetType":"codexRateLimits","status":"available","grantedAt":0,"expiresAt":\(resetDate + 86400 * 30),"title":"Full reset (Weekly + 5 hr)"}
            """
            let credits = count == 0 ? "" : count == 1 ? credit2 : credit1 + "," + credit2
            snapshot = try! JSONDecoder().decode(UsageSnapshot.self, from: Data("""
            {"rateLimits":{"limitId":"codex","planType":"plus",
            "primary":{"usedPercent":\(used),"windowDurationMins":300,"resetsAt":\(scenario == .resetSuccess ? now.addingTimeInterval(17940).timeIntervalSince1970 : firstReset)},
            "secondary":{"usedPercent":\(used),"windowDurationMins":10080,"resetsAt":\(scenario == .resetSuccess ? now.addingTimeInterval(601200).timeIntervalSince1970 : secondReset)}},
            "rateLimitResetCredits":{"availableCount":\(count),"credits":[\(credits)]}}
            """.utf8))
            lastUpdated = now
        }
        switch scenario {
        case .loading: isRefreshing = true
        case .refreshFailed, .refreshFailedEmpty: failure = .refresh
        case .retrying, .retryingEmpty: failure = .refresh; isRefreshing = true
        case .codexMissing: failure = .codexMissing
        case .signInRequired: failure = .signInRequired
        case .resetConfirm: resetInteraction.select("preview-1")
        case .resetProcessing:
            resetInteraction.select("preview-1")
            _ = resetInteraction.begin("preview-1")
        case .resetError:
            resetInteraction.select("preview-1")
            let attempt = resetInteraction.begin("preview-1")!
            resetInteraction.finish(attempt, outcome: nil, showError: true)
        case .ready, .expired, .noResets, .resetSuccess: break
        }
    }
}
