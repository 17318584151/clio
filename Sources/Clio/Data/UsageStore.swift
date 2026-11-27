import Foundation
import Combine
import AppKit

/// Owns the log readers off the main actor. Parsing runs here so the panel
/// stays responsive while ~1 GiB of session logs is walked.
actor LogReaders {
    private let claude: ClaudeCodeReader
    private let codex: CodexReader
    private let antigravity: AntigravityReader

    private var codexQuota: RateLimitSnapshot?
    private var parsed: Result?
    private var cacheKey: UsageCacheKey?
    private var cachedSnapshots: [ToolSnapshot] = []
    private var cachedCombined = UsageSummary.empty
    private var cachedCategories: [CategoryUsage] = []

    private struct UsageCacheKey: Equatable {
        var claudeRevision: Int
        var codexRevision: Int
        var antigravityRevision: Int
        var prices: PriceTable
        var history: [Date: Int]
        var claudeLedger: UsageLedger?
        var codexLedger: UsageLedger?
        var antigravityLedger: UsageLedger?
        var categoryLedger: CategoryLedger?
        var retentionDays: Int?
        var day: Date
        var calendar: Calendar
    }

    struct Result: Sendable {
        var claudeEvents: [UsageEvent] = []
        var claudeRejections: [QuotaRejection] = []
        var codexEvents: [UsageEvent] = []
        var codexQuota: RateLimitSnapshot?
        var antigravityEvents: [UsageEvent] = []
        var claudeAvailable = false
        var codexAvailable = false
        var antigravityAvailable = false
    }

    init(claude: ClaudeCodeReader = ClaudeCodeReader(), codex: CodexReader = CodexReader(),
         antigravity: AntigravityReader = AntigravityReader()) {
        self.claude = claude
        self.codex = codex
        self.antigravity = antigravity
    }

    func refresh() -> Result {
        var result = Result()
        result.claudeAvailable = claude.isAvailable
        result.codexAvailable = codex.isAvailable
        let claudeReading = claude.refresh()
        result.claudeEvents = claudeReading.events
        result.claudeRejections = claudeReading.rejections
        let codexReading = codex.refresh()
        result.codexEvents = codexReading.events
        result.codexQuota = codexReading.quota
        result.antigravityAvailable = antigravity.isAvailable
        result.antigravityEvents = antigravity.refresh()
        return result
    }

    /// Quota updates reuse parsed events; unchanged usage inputs reuse the summaries.
    func dashboard(prices: PriceTable, quota: [Tool: DashboardBuilder.QuotaConfig], quotaMaxAge: TimeInterval,
                   scanLogs: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> Dashboard {
        if scanLogs || parsed == nil { parsed = refresh() }
        let parsed = parsed!
        let history = StatsCacheReader.dailyTokens()
        var storedClaude = UsageLedger.load(for: .claudeCode)
        var storedCodex = UsageLedger.load(for: .codex)
        var storedAntigravity = UsageLedger.load(for: .antigravity)
        let retentionDays = UsageLedger.retentionDays()
        let categoryLedger = CategoryLedger.load()
        var key = UsageCacheKey(claudeRevision: claude.revision, codexRevision: codex.revision,
                                antigravityRevision: antigravity.revision,
                                prices: prices, history: history, claudeLedger: storedClaude,
                                codexLedger: storedCodex, antigravityLedger: storedAntigravity,
                                categoryLedger: categoryLedger, retentionDays: retentionDays,
                                day: calendar.startOfDay(for: now), calendar: calendar)
        let reuseUsage = key == cacheKey

        var snapshots: [ToolSnapshot] = []
        var events: [UsageEvent] = []
        if (parsed.claudeAvailable && !parsed.claudeEvents.isEmpty) || storedClaude?.days.isEmpty == false || !history.isEmpty {
            let ledger = (reuseUsage ? storedClaude : nil) ?? UsageLedger.updated(storedClaude, events: parsed.claudeEvents, history: history,
                                             now: now, retentionDays: retentionDays, calendar: calendar)
            if ledger != storedClaude { ledger.save(for: .claudeCode) }
            storedClaude = ledger
            snapshots.append(DashboardBuilder.snapshot(tool: .claudeCode,
                                                       events: parsed.claudeEvents,
                                                       rejections: parsed.claudeRejections,
                                                       prices: prices,
                                                       quota: quota[.claudeCode] ?? .init(), ledger: ledger,
                                                       cachedUsage: reuseUsage ? cachedSnapshots.first { $0.tool == .claudeCode }?.usage : nil,
                                                       now: now, calendar: calendar))
            if !reuseUsage { events += parsed.claudeEvents }
        }
        if (parsed.codexAvailable && !parsed.codexEvents.isEmpty) || storedCodex?.days.isEmpty == false {
            let ledger = (reuseUsage ? storedCodex : nil) ?? UsageLedger.updated(storedCodex, events: parsed.codexEvents, history: [:],
                                             now: now, retentionDays: Int(LogScanner.retention / 86400), calendar: calendar)
            if ledger != storedCodex { ledger.save(for: .codex) }
            storedCodex = ledger
            var config = quota[.codex] ?? .init()
            codexQuota = RateLimitSnapshot.latest([config.rateLimits, parsed.codexQuota, codexQuota].compactMap { $0 },
                                                  now: now, maxAge: quotaMaxAge)
            config.rateLimits = codexQuota
            snapshots.append(DashboardBuilder.snapshot(tool: .codex,
                                                       events: parsed.codexEvents,
                                                       rejections: [],
                                                       prices: prices,
                                                       quota: config, ledger: ledger,
                                                       cachedUsage: reuseUsage ? cachedSnapshots.first { $0.tool == .codex }?.usage : nil,
                                                       now: now, calendar: calendar))
            if !reuseUsage { events += parsed.codexEvents }
        }
        if (parsed.antigravityAvailable && !parsed.antigravityEvents.isEmpty) || storedAntigravity?.days.isEmpty == false {
            let ledger = (reuseUsage ? storedAntigravity : nil) ?? UsageLedger.updated(storedAntigravity, events: parsed.antigravityEvents,
                                             history: [:], now: now, retentionDays: Int(LogScanner.retention / 86400), calendar: calendar)
            if ledger != storedAntigravity { ledger.save(for: .antigravity) }
            storedAntigravity = ledger
            snapshots.append(DashboardBuilder.snapshot(tool: .antigravity,
                                                       events: parsed.antigravityEvents,
                                                       rejections: [],
                                                       prices: prices,
                                                       quota: quota[.antigravity] ?? .init(), ledger: ledger,
                                                       cachedUsage: reuseUsage ? cachedSnapshots.first { $0.tool == .antigravity }?.usage : nil,
                                                       now: now, calendar: calendar))
            if !reuseUsage { events += parsed.antigravityEvents }
        }
        if !reuseUsage {
            cachedCategories = DashboardBuilder.categorized([
                (.claudeCode, parsed.claudeEvents, storedClaude), (.codex, parsed.codexEvents, storedCodex),
                (.antigravity, parsed.antigravityEvents, storedAntigravity)
            ], prices: prices, now: now, calendar: calendar, verified: categoryLedger)
            cachedCombined = DashboardBuilder.combined(cachedCategories.map(\.usage), events: events, now: now, calendar: calendar)
        }
        cachedSnapshots = snapshots
        key.claudeLedger = storedClaude
        key.codexLedger = storedCodex
        key.antigravityLedger = storedAntigravity
        cacheKey = key
        return Dashboard(snapshots: snapshots, combined: cachedCombined, updatedAt: now, categories: cachedCategories)
    }
}

/// Main-actor requests share one worker; a pending log scan takes priority.
struct RefreshRequests {
    private var isRunning = false
    private var pending: Bool?

    mutating func request(scanLogs: Bool) -> Bool {
        pending = (pending ?? false) || scanLogs
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func next() -> Bool? {
        guard let request = pending else {
            isRunning = false
            return nil
        }
        pending = nil
        return request
    }
}

/// Owns the readers, the refresh timer, and the current dashboard.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accountQuotas: [AccountQuota] = []
    @Published var accountDirectoryError: String?
    @Published private(set) var queryingAccountIDs: Set<String> = []
    /// Which accounts Orca can switch to and currently launches with.
    @Published private(set) var orca: OrcaAccounts?
    @Published private(set) var switchingAccountID: String?
    @Published private(set) var switchErrors: [String: String] = [:]
    private var lastOrcaLoad: Date?
    private var lastAccountQueries: [String: Date] = [:]
    private var lastDefaultCodexQuery: Date?
    private let accountQuery: @Sendable (QuotaAccount) -> AccountQuota
    private let codexQuery: @Sendable () -> CodexUsageProbe.Reading?
    private var extraAccountDirectories: [String] {
        UserDefaults.standard.stringArray(forKey: "accountDirectories") ?? []
    }

    func addAccountDirectory(_ directory: URL) {
        guard QuotaAccount.read(directory: directory) != nil else {
            accountDirectoryError = "该目录中未找到 Claude Code 或 Codex 的账号信息。请选择对应的配置目录。"
            return
        }
        let paths = Array(Set(extraAccountDirectories + [directory.standardizedFileURL.resolvingSymlinksInPath().path])).sorted()
        UserDefaults.standard.set(paths, forKey: "accountDirectories")
        accountDirectoryError = nil
        refreshAccounts(force: true)
    }

    func isCustomAccount(_ account: QuotaAccount) -> Bool {
        extraAccountDirectories.contains(account.directory.path)
    }

    func removeAccountDirectory(_ account: QuotaAccount) {
        UserDefaults.standard.set(extraAccountDirectories.filter { $0 != account.directory.path }, forKey: "accountDirectories")
        accountQuotas.removeAll { $0.account == account }
        lastAccountQueries.removeAll()
        refreshAccounts(force: true)
    }

    /// Status-line tools re-read their pushed feed each time; only Codex is queried.
    func refreshAccounts(force: Bool = false) {
        guard !isPreview else { return }
        let accounts = QuotaAccount.discover(extraDirectories: extraAccountDirectories)
        let now = Date()
        let previousAccounts = Dictionary(uniqueKeysWithValues: accountQuotas.map { ($0.id, $0) })
        accountQuotas = accounts.map { account in
            guard account.tool == .codex else { return AccountQuota.cached(account) }
            return previousAccounts[account.id].flatMap { $0.account == account ? $0 : nil } ?? AccountQuota.cached(account)
        }
        let interval = prefs.codexQuotaInterval
        let pending = accountQuotas.filter { reading in
            reading.account.tool == .codex && !queryingAccountIDs.contains(reading.id)
                && (force || lastAccountQueries[reading.id].map { now.timeIntervalSince($0) >= interval } ?? true)
        }
        queryAccounts(pending)
        loadOrcaIfDue()
    }

    /// Selections made in Orca itself show up within a minute.
    private func loadOrcaIfDue(force: Bool = false) {
        guard force || lastOrcaLoad.map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
              OrcaAccounts.executable != nil else { return }
        lastOrcaLoad = Date()
        let accounts = accountQuotas.map(\.account)
        Task { [weak self] in
            let state = await Task.detached(priority: .utility) { OrcaAccounts.load(accounts: accounts) }.value
            self?.orca = state
        }
    }

    /// Same effect as Orca's status-bar switcher: agents launched afterwards use this account.
    func useInOrca(_ account: QuotaAccount) {
        guard switchingAccountID == nil, let target = orca?.targets[account.id] else { return }
        switchingAccountID = account.id
        switchErrors[account.id] = nil
        let accounts = accountQuotas.map(\.account)
        Task { [weak self] in
            let (error, state) = await Task.detached(priority: .userInitiated) {
                (OrcaAccounts.select(target), OrcaAccounts.load(accounts: accounts))
            }.value
            guard let self else { return }
            self.switchErrors[account.id] = error
            self.orca = state ?? self.orca
            self.lastOrcaLoad = Date()
            self.switchingAccountID = nil
        }
    }

    private func queryAccounts(_ pending: [AccountQuota]) {
        guard !pending.isEmpty else { return }
        queryingAccountIDs.formUnion(pending.map(\.id))
        let query = accountQuery
        Task { [weak self] in
            for item in pending {
                guard let self else { break }
                let account = item.account
                self.lastAccountQueries[account.id] = Date()
                let reading = await Task.detached(priority: .utility) { query(account) }.value
                if let index = self.accountQuotas.firstIndex(where: { $0.account == account }) {
                    self.accountQuotas[index] = reading
                }
                if account.isDefault {
                    self.codexReading = .init(quota: reading.quota, plan: reading.plan, remainingResets: reading.remainingResets)
                    await self.rebuildDashboard(scanLogs: false)
                }
                self.queryingAccountIDs.remove(account.id)
            }
        }
    }
    @Published private(set) var dashboard = Dashboard(snapshots: [], combined: .empty, updatedAt: .distantPast)
    @Published private(set) var isLoading = true
    @Published private(set) var priceOrigin: PriceOrigin = .builtin
    /// When the price table was last read from models.dev.
    @Published private(set) var priceFetchedAt: Date?

    /// Raised when a 100M milestone is crossed; the celebration window observes it.
    let milestoneReached = PassthroughSubject<Void, Never>()

    private var isPreview = false
    private let readers: LogReaders
    private let prefs = Preferences.shared
    private var timer: Timer?
    private var refreshRequests = RefreshRequests()
    private var claudeQuota: RateLimitSnapshot?
    private var codexReading: CodexUsageProbe.Reading?
    @Published private var codexProbeInFlight = false
    private var lastAccountFeeds: [String: RateLimitSnapshot] = [:]
    private var quotaWatch: DispatchSourceFileSystemObject?
    private var cancellables: Set<AnyCancellable> = []

    init(readers: LogReaders = LogReaders(),
         accountQuery: @escaping @Sendable (QuotaAccount) -> AccountQuota = { AccountQuota.fetch($0) },
         codexQuery: @escaping @Sendable () -> CodexUsageProbe.Reading? = { CodexUsageProbe.fetch() }) {
        self.readers = readers
        self.accountQuery = accountQuery
        self.codexQuery = codexQuery
        accountQuotas = QuotaAccount.discover(extraDirectories: extraAccountDirectories).map { AccountQuota.cached($0) }
        prefs.$refreshInterval
            .removeDuplicates()
            .sink { [weak self] interval in self?.startTimer(interval) }
            .store(in: &cancellables)
    }

    func start() {
        refreshAccounts()
        Task { await refresh() }
        Task {
            await refreshPricesIfNeeded()
        }
        startTimer(prefs.refreshInterval)
        watchQuotaFeed()
    }

    /// The status-line feed is written whenever Claude Code renders, which is
    /// not on our schedule. Watching the directory picks a new payload up as it
    /// lands instead of on the next tick.
    private func watchQuotaFeed() {
        let descriptor = open(AppPaths.support.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                              eventMask: [.write],
                                                              queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.refreshIfFeedChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        quotaWatch = source
    }

    /// The directory also holds files this app writes itself, so a rebuild only
    /// happens when the feed itself changed.
    private func refreshIfFeedChanged() async {
        guard accountFeeds() != lastAccountFeeds else { return }
        await refresh(scanLogs: false)
    }

    private func accountFeeds() -> [String: RateLimitSnapshot] {
        accountQuotas.reduce(into: [:]) { feeds, reading in
            if reading.account.tool != .codex {
                feeds[reading.id] = RateLimitBridge.load(accountID: reading.id)
            }
        }
    }

    private func startTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(5, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
                await self?.refreshPricesIfNeeded()
            }
        }
    }

    private func refreshPricesIfNeeded() async {
        let previous = await PriceService.shared.table()
        await PriceService.shared.refreshIfNeeded()
        if await PriceService.shared.table() != previous {
            await rebuildDashboard(scanLogs: false)
        } else {
            priceOrigin = await PriceService.shared.origin
            priceFetchedAt = await PriceService.shared.lastFetch
        }
    }

    func refresh(scanLogs: Bool = true) async {
        guard !isPreview else { return }
        guard refreshRequests.request(scanLogs: scanLogs) else { return }
        while let scanLogs = refreshRequests.next() {
            await performRefresh(scanLogs: scanLogs)
        }
    }

    private func performRefresh(scanLogs: Bool) async {
        lastAccountFeeds = accountFeeds()
        refreshAccounts()
        await rebuildDashboard(scanLogs: scanLogs)
        probeIfDue()
    }

    /// Reuse current account state; quota and price updates do not rediscover logins.
    private func rebuildDashboard(scanLogs: Bool) async {
        let prices = await PriceService.shared.table()
        let defaultAccount = accountQuotas.first { $0.account.tool == .claudeCode && $0.account.isDefault }
        let feed = defaultAccount?.quota
        let config = ClaudeConfigReader.read()
        // Pushed and cached quotas are never refreshed on demand, so they hold until their windows reset.
        let liveLimits = RateLimitSnapshot.merged([feed, config].compactMap { $0 },
                                                  now: Date(),
                                                  maxAge: .infinity)?.stabilized(against: claudeQuota, now: Date())
        claudeQuota = liveLimits
        let origin = await PriceService.shared.origin
        let fetchedAt = await PriceService.shared.lastFetch

        let antigravityLimits = accountQuotas.first { $0.account.tool == .antigravity }?.quota
        let quotaConfig = Tool.allCases.reduce(into: [Tool: DashboardBuilder.QuotaConfig]()) { table, tool in
            let configured = prefs.planName[tool.rawValue]
            let detected: (plan: String?, limits: RateLimitSnapshot?) = switch tool {
            // The tier Claude Code records locally, unless overridden.
            case .claudeCode: (PlanReader.claudeCodePlan(), liveLimits)
            case .codex: (codexReading?.plan, codexReading?.quota)
            case .antigravity: (nil, antigravityLimits)
            }
            table[tool] = DashboardBuilder.QuotaConfig(
                planName: (configured?.isEmpty == false ? configured : nil) ?? detected.plan,
                rateLimits: detected.limits,
                remainingResets: tool == .codex ? codexReading?.remainingResets : nil
            )
        }

        let built = await readers.dashboard(prices: prices, quota: quotaConfig,
                                             quotaMaxAge: prefs.codexQuotaInterval * 2, scanLogs: scanLogs)

        priceOrigin = origin
        priceFetchedAt = fetchedAt
        dashboard = built
        isLoading = false

        checkMilestone(built.combined)
    }

    var isQueryingQuota: Bool { !queryingAccountIDs.isEmpty || codexProbeInFlight }

    /// Opening the panel checks Codex; the other tools report through their status line.
    func probeNow() {
        guard !isPreview else { return }
        refreshAccounts()
        probeIfDue()
    }

    /// A default Codex login without a readable identity is still queried on its own schedule.
    private func probeIfDue() {
        let due = lastDefaultCodexQuery.map { Date().timeIntervalSince($0) >= prefs.codexQuotaInterval } ?? true
        guard due, !codexProbeInFlight,
              !accountQuotas.contains(where: { $0.account.tool == .codex && $0.account.isDefault }) else { return }
        codexProbeInFlight = true
        let query = codexQuery
        Task { [weak self] in
            guard let self else { return }
            self.lastDefaultCodexQuery = Date()
            let reading = await Task.detached(priority: .utility, operation: { query() }).value
            self.codexReading = reading
            self.codexProbeInFlight = false
            await self.refresh(scanLogs: false)
        }
    }

    /// Daily milestones use the combined usage of both tools.
    private func checkMilestone(_ usage: UsageSummary) {
        let previous = prefs.loadMilestones()
        let current = Milestones.state(dayTokens: usage.totals[.day]?.total ?? 0,
                                       weekTokens: usage.totals[.week]?.total ?? 0,
                                       monthTokens: usage.totals[.month]?.total ?? 0,
                                       at: Date())
        let fire = Milestones.shouldCelebrate(previous: previous, current: current)
        prefs.saveMilestones(Milestones.merged(previous: previous, current: current))
        if fire && prefs.confettiEnabled {
            milestoneReached.send()
        }
    }

    /// A store holding a fixed dashboard, for rendering a design comparison.
    static func preview(_ dashboard: Dashboard, accounts: [AccountQuota] = [],
                        orca: OrcaAccounts? = nil) -> UsageStore {
        let store = UsageStore()
        store.isPreview = true
        store.accountQuotas = accounts
        store.orca = orca
        store.timer?.invalidate()
        store.timer = nil
        store.dashboard = dashboard
        store.isLoading = false
        return store
    }

    func openLogDirectory(for tool: Tool) {
        NSWorkspace.shared.open(tool.logDirectory)
    }
}
