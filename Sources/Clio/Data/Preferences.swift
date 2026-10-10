import Foundation
import Combine
import ServiceManagement

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case iconOnly
    case iconAndWindowPercent
    case iconAndTodayTokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: return "仅图标"
        case .iconAndWindowPercent: return "图标 + 窗口百分比"
        case .iconAndTodayTokens: return "图标 + 今日 Token 数"
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// User settings. Everything lives in UserDefaults except the milestone
/// snapshot, which is kept as a file so a defaults reset can't replay a
/// celebration the user already saw.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var confettiEnabled: Bool { didSet { defaults.set(confettiEnabled, forKey: "confettiEnabled") } }
    @Published var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    /// How often Claude Code is asked for the quota state in the background.
    @Published var quotaInterval: TimeInterval { didSet { defaults.set(quotaInterval, forKey: "quotaInterval") } }
    @Published var menuBarDisplay: MenuBarDisplay { didSet { defaults.set(menuBarDisplay.rawValue, forKey: "menuBarDisplay") } }
    /// The menu bar shows the app icon and every tool's tokens together, rather
    /// than the selected account's ring and tokens.
    @Published var mergedMenuBar: Bool { didSet { defaults.set(mergedMenuBar, forKey: "mergedMenuBar") } }
    /// The account the menu bar follows when not merged.
    @Published var selectedTool: Tool { didSet { defaults.set(selectedTool.rawValue, forKey: "selectedTool") } }
    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    /// Takes effect only from macOS 26, where the material exists.
    @Published var liquidGlass: Bool { didSet { defaults.set(liquidGlass, forKey: "liquidGlass") } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    /// Applies only while `autoCheckUpdates` is on.
    @Published var autoInstallUpdates: Bool { didSet { defaults.set(autoInstallUpdates, forKey: "autoInstallUpdates") } }

    /// Overrides the plan label read from Claude Code's own config.
    @Published var planName: [String: String] { didSet { defaults.set(planName, forKey: "planName") } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    private init() {
        defaults.register(defaults: [
            "confettiEnabled": true,
            "refreshInterval": 30.0,
            "quotaInterval": 1800.0,
            "menuBarDisplay": MenuBarDisplay.iconAndTodayTokens.rawValue,
            "mergedMenuBar": true,
            "selectedTool": Tool.claudeCode.rawValue,
            "appearance": Appearance.system.rawValue,
            "liquidGlass": false,
            "autoCheckUpdates": true,
            "autoInstallUpdates": true,
        ])
        confettiEnabled = defaults.bool(forKey: "confettiEnabled")
        refreshInterval = defaults.double(forKey: "refreshInterval")
        quotaInterval = defaults.double(forKey: "quotaInterval")
        menuBarDisplay = MenuBarDisplay(rawValue: defaults.string(forKey: "menuBarDisplay") ?? "") ?? .iconAndTodayTokens
        mergedMenuBar = defaults.bool(forKey: "mergedMenuBar")
        selectedTool = Tool(rawValue: defaults.string(forKey: "selectedTool") ?? "") ?? .claudeCode
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        liquidGlass = defaults.bool(forKey: "liquidGlass")
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        autoInstallUpdates = defaults.bool(forKey: "autoInstallUpdates")
        planName = defaults.dictionary(forKey: "planName") as? [String: String] ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The merged item has no ring, so the window percentage gives way to the
    /// token count there.
    var effectiveMenuBarDisplay: MenuBarDisplay {
        mergedMenuBar && menuBarDisplay == .iconAndWindowPercent ? .iconAndTodayTokens : menuBarDisplay
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails for an app that isn't in a signed bundle
            // (a development build run from ./build). Reflect the real state
            // rather than leaving the toggle lying.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Milestone snapshot

    private var milestonePath: URL { AppPaths.support.appending(path: "milestones.json") }

    func loadMilestones() -> MilestoneState? {
        guard let data = try? Data(contentsOf: milestonePath) else { return nil }
        return try? JSONDecoder().decode(MilestoneState.self, from: data)
    }

    func saveMilestones(_ state: MilestoneState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: milestonePath, options: .atomic)
    }
}
