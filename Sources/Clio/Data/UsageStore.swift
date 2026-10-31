import Foundation
import Combine
import AppKit

/// Owns both log readers off the main actor. Parsing runs here so the panel
/// stays responsive while ~1 GiB of session logs is walked.
actor LogReaders {
    private let claude: ClaudeCodeReader
    private let codex: CodexReader

    private var codexQuota: RateLimitSnapshot?
    private var codexRemainingResets: Int?
    private var parsed: Result?
    private var cacheKey: UsageCacheKey?
    private var cachedSnapshots: [ToolSnapshot] = []
    private var cachedCombined = UsageSummary.empty

    private struct UsageCacheKey: Equatable {
        var claudeRevision: Int
        var codexRevision: Int
        var prices: PriceTable
        var history: [Date: Int]
        var claudeLedger: UsageLedger?
        var codexLedger: UsageLedger?
        var retentionDays: Int?
        var day: Date
        var calendar: Calendar
    }

    struct Result: Sendable {
        var claudeEvents: [UsageEvent] = []
        var claudeRejections: [QuotaRejection] = []
        var codexEvents: [UsageEvent] = []
        var codexQuota: RateLimitSnapshot?
        var claudeAvailable = false
        var codexAvailable = false
    }

    init(claude: ClaudeCodeReader = ClaudeCodeReader(), codex: CodexReader = CodexReader()) {
        self.claude = claude
        self.codex = codex
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
        let retentionDays = UsageLedger.retentionDays()
        var key = UsageCacheKey(claudeRevision: claude.revision, codexRevision: codex.revision,
                                prices: prices, history: history, claudeLedger: storedClaude,
                                codexLedger: storedCodex, retentionDays: retentionDays,
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
            let latest = RateLimitSnapshot.latest([config.rateLimits, parsed.codexQuota, codexQuota].compactMap { $0 },
                                                   now: now, maxAge: quotaMaxAge)
            let resetUsed = config.remainingResets.flatMap { count in codexRemainingResets.map { count < $0 } } ?? false
            let afterReset = config.rateLimits.flatMap { api in latest.map { $0.updatedAt >= api.updatedAt } } ?? false
            codexQuota = latest?.stabilized(against: codexQuota, now: now,
                                            allowsDecrease: resetUsed && afterReset)
            if let count = config.remainingResets, !resetUsed || afterReset { codexRemainingResets = count }
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
        if !reuseUsage {
            cachedCombined = DashboardBuilder.combined(snapshots.map(\.usage), events: events, now: now, calendar: calendar)
        }
        cachedSnapshots = snapshots
        key.claudeLedger = storedClaude
        key.codexLedger = storedCodex
        cacheKey = key
        return Dashboard(snapshots: snapshots, combined: cachedCombined, updatedAt: now)
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
    @Published private var accountQueryInFlight = false
    private var lastAccountQueries: [String: Date] = [:]
    private var lastDefaultQueries: [Tool: Date] = [:]
    private let accountQuery: @Sendable (QuotaAccount, TimeInterval, Bool) -> AccountQuota
    private let claudeQuery: @Sendable (TimeInterval) -> RateLimitSnapshot?
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

    func refreshAccounts(force: Bool = false, manual: Bool = false) {
        guard !isPreview, !accountQueryInFlight else { return }
        let accounts = QuotaAccount.discover(extraDirectories: extraAccountDirectories)
        let maxAge = prefs.quotaInterval
        let now = Date()
        accountQuotas = accounts.map { account in
            let previous = accountQuotas.first { $0.account == account }
            guard account.tool == .claudeCode else { return previous ?? AccountQuota.cached(account) }
            var local = AccountQuota.cached(account)
            if prefs.automaticClaudeQuotaQueries, previous?.status == "查询失败",
               !ClaudeConfigReader.isFresh(local.quota, maxAge: maxAge, now: now) {
                local.quota = nil
                local.status = "查询失败"
            }
            if !manual, !prefs.automaticClaudeQuotaQueries { local.status = "仅本地缓存" }
            return local
        }
        let pending = accountQuotas.filter { reading in
            if !manual, reading.account.tool == .claudeCode {
                guard prefs.automaticClaudeQuotaQueries else { return false }
                if ClaudeConfigReader.isFresh(reading.quota, maxAge: maxAge, now: now) { return false }
            }
            let interval = prefs.queryInterval(for: reading.account.tool)
            return force || lastAccountQueries[reading.id].map { now.timeIntervalSince($0) >= interval } ?? true
        }
        guard !pending.isEmpty else { return }
        accountQueryInFlight = true
        let query = accountQuery
        Task { [weak self] in
            for item in pending {
                guard let self else { break }
                let account = item.account
                if !manual, account.tool == .claudeCode, !self.prefs.automaticClaudeQuotaQueries { continue }
                let maxAge = self.prefs.queryInterval(for: account.tool)
                self.lastAccountQueries[account.id] = Date()
                let reading = await Task.detached(priority: .utility) { query(account, maxAge, manual) }.value
                if let index = self.accountQuotas.firstIndex(where: { $0.account == account }) {
                    self.accountQuotas[index] = reading
                }
                if account.isDefault, account.tool == .codex {
                    self.codexReading = .init(quota: reading.quota, plan: reading.plan, remainingResets: reading.remainingResets)
                }
                await self.refresh(scanLogs: false)
            }
            self?.accountQueryInFlight = false
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
    @Published private var probeInFlight = false
    private var claudeQuota: RateLimitSnapshot?
    private var codexReading: CodexUsageProbe.Reading?
    @Published private var codexProbeInFlight = false
    private var lastFeedUpdate: Date?
    private var quotaWatch: DispatchSourceFileSystemObject?
    private var cancellables: Set<AnyCancellable> = []

    init(readers: LogReaders = LogReaders(),
         accountQuery: @escaping @Sendable (QuotaAccount, TimeInterval, Bool) -> AccountQuota = { account, maxAge, force in
             AccountQuota.fetch(account, maxAge: maxAge, force: force)
         },
         claudeQuery: @escaping @Sendable (TimeInterval) -> RateLimitSnapshot? = { UsageProbe.fetch(maxAge: $0) },
         codexQuery: @escaping @Sendable () -> CodexUsageProbe.Reading? = { CodexUsageProbe.fetch() }) {
        self.readers = readers
        self.accountQuery = accountQuery
        self.claudeQuery = claudeQuery
        self.codexQuery = codexQuery
        accountQuotas = QuotaAccount.discover(extraDirectories: extraAccountDirectories).map(AccountQuota.cached)
        prefs.$refreshInterval
            .removeDuplicates()
            .sink { [weak self] interval in self?.startTimer(interval) }
            .store(in: &cancellables)
    }

    func start() {
        refreshAccounts()
        Task { await refresh() }
        Task {
            await PriceService.shared.refreshIfNeeded()
            await refresh(scanLogs: false)
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
        guard RateLimitBridge.load()?.updatedAt != lastFeedUpdate else { return }
        await refresh(scanLogs: false)
    }

    private func startTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(5, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
                await PriceService.shared.refreshIfNeeded()
                await self?.refresh(scanLogs: false)
            }
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
        refreshAccounts()
        let prices = await PriceService.shared.table()
        let feed = RateLimitBridge.load()
        lastFeedUpdate = feed?.updatedAt
        let config = ClaudeConfigReader.read()
        // Fresh enough to trust: two polling periods, so raising the interval
        // in Settings doesn't make the panel drop the percentages in between.
        let maxAge = prefs.quotaInterval * 2
        let liveLimits = RateLimitSnapshot.merged([feed, config].compactMap { $0 },
                                                  now: Date(),
                                                  maxAge: maxAge)?.stabilized(against: claudeQuota, now: Date())
        claudeQuota = liveLimits
        let origin = await PriceService.shared.origin
        let fetchedAt = await PriceService.shared.lastFetch

        let quotaConfig = Tool.allCases.reduce(into: [Tool: DashboardBuilder.QuotaConfig]()) { table, tool in
            let configured = prefs.planName[tool.rawValue]
            table[tool] = DashboardBuilder.QuotaConfig(
                // The tier Claude Code records locally, unless overridden.
                planName: (configured?.isEmpty == false ? configured : nil)
                    ?? (tool == .claudeCode ? PlanReader.claudeCodePlan() : codexReading?.plan),
                rateLimits: tool == .claudeCode ? liveLimits : codexReading?.quota,
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
        probeIfDue()
    }

    var isQueryingQuota: Bool { accountQueryInFlight || probeInFlight || codexProbeInFlight }

    /// Opening the panel checks Codex and follows Claude's automatic-query preference.
    func probeNow() {
        guard !isPreview else { return }
        refreshAccounts()
        probeIfDue()
    }

    /// One explicit query batch, without enabling future automatic queries.
    func queryQuotasNow() {
        guard !isPreview, !isQueryingQuota else { return }
        refreshAccounts(force: true, manual: true)
        probeIfDue(force: true, manual: true)
    }

    /// Default accounts without readable identities still use their tool's own policy.
    private func probeIfDue(force: Bool = false, manual: Bool = false) {
        func due(_ tool: Tool) -> Bool {
            force || lastDefaultQueries[tool].map { Date().timeIntervalSince($0) >= prefs.queryInterval(for: tool) } ?? true
        }
        let queryClaude = (manual || prefs.automaticClaudeQuotaQueries) && due(.claudeCode) && !probeInFlight
            && !accountQuotas.contains(where: { $0.account.tool == .claudeCode && $0.account.isDefault })
            && (manual || !ClaudeConfigReader.isFresh(ClaudeConfigReader.read(), maxAge: prefs.quotaInterval))
        let queryCodex = due(.codex) && !codexProbeInFlight
            && !accountQuotas.contains(where: { $0.account.tool == .codex && $0.account.isDefault })
        guard queryClaude || queryCodex else { return }
        if queryClaude {
            probeInFlight = true
            let maxAge = prefs.quotaInterval
            let query = claudeQuery
            Task { [weak self] in
                guard let self else { return }
                guard manual || self.prefs.automaticClaudeQuotaQueries else {
                    self.probeInFlight = false
                    return
                }
                self.lastDefaultQueries[.claudeCode] = Date()
                let probed = await Task.detached(priority: .utility, operation: { query(maxAge) }).value
                self.probeInFlight = false
                // /usage writes the actual fetch time into Claude's local cache.
                guard probed != nil else { return }
                await self.refresh(scanLogs: false)
            }
        }
        if queryCodex {
            codexProbeInFlight = true
            let query = codexQuery
            Task { [weak self] in
                guard let self else { return }
                self.lastDefaultQueries[.codex] = Date()
                let reading = await Task.detached(priority: .utility, operation: { query() }).value
                self.codexReading = reading
                self.codexProbeInFlight = false
                await self.refresh(scanLogs: false)
            }
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
    static func preview(_ dashboard: Dashboard, accounts: [AccountQuota] = []) -> UsageStore {
        let store = UsageStore()
        store.isPreview = true
        store.accountQuotas = accounts
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
