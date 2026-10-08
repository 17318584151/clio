import AppKit
import Combine
import CryptoKit

/// Checks GitHub Releases for a newer build and installs it in place.
///
/// Sparkle is not an option here: it refuses an update whose code signature
/// differs from the running app's, and every ad-hoc build carries a different
/// one. The download goes through URLSession, which sets no quarantine flag, so
/// the replaced app opens without a Gatekeeper prompt.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let assetURL: URL
        /// Hex SHA-256 from the asset's `digest`, when GitHub reports one.
        let sha256: String?
        /// The disk image's size in bytes.
        let size: Int?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        /// Downloading in the background ahead of an automatic install.
        case downloading(Release)
        /// Downloaded and verified; installs once no window is open.
        case ready(Release)
        case installing(Release)
        case failed(String)
    }

    /// A verified disk image and the temporary directory holding it.
    private struct Download {
        let release: Release
        let image: URL
        let workspace: URL
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?
    /// The version an automatic update installed, until the panel has shown it.
    @Published private(set) var justUpdated: String?

    /// Whether the panel or the Settings window is on screen.
    var windowsOpen: () -> Bool = { false }

    static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private static let repository = "UreMySunshine/clio"
    private static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    private static let checkInterval: TimeInterval = 24 * 3600
    private static let lastCheckedKey = "lastUpdateCheck"
    private static let justUpdatedKey = "justUpdatedTo"

    private var prefs: Preferences?
    private var staged: Download?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    var availableRelease: Release? {
        switch phase {
        case .available(let release), .ready(let release): return release
        default: return nil
        }
    }

    private var installsAutomatically: Bool {
        prefs?.autoCheckUpdates == true && prefs?.autoInstallUpdates == true
    }

    private init() {
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
        if UserDefaults.standard.string(forKey: Self.justUpdatedKey) == Self.currentVersion {
            justUpdated = Self.currentVersion
        } else {
            UserDefaults.standard.removeObject(forKey: Self.justUpdatedKey)
        }
    }

    /// Checks now if a day has passed, then hourly asks whether one has again.
    func start(prefs: Preferences) {
        self.prefs = prefs
        prefs.$autoCheckUpdates.combineLatest(prefs.$autoInstallUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.followAutoInstallSetting() }
            .store(in: &cancellables)
        prefs.$autoCheckUpdates
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.timer?.invalidate()
                self.timer = nil
                guard enabled else { return }
                self.checkIfDue()
                self.timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkIfDue() }
                }
            }
            .store(in: &cancellables)
    }

    private func checkIfDue() {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        Task { await check() }
    }

    func check() async {
        switch phase {
        case .checking, .downloading, .ready, .installing: return
        default: break
        }
        phase = .checking
        do {
            var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateError("GitHub 返回 \(status)") }
            let release = try Self.parse(data)
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
            phase = Self.isNewer(release.version, than: Self.currentVersion) ? .available(release) : .upToDate
            await stage(release)
        } catch {
            phase = .failed("检查失败：\(error.localizedDescription)")
        }
    }

    /// Clears the post-update notice once the panel has shown it.
    func acknowledgeUpdate() {
        guard justUpdated != nil else { return }
        justUpdated = nil
        UserDefaults.standard.removeObject(forKey: Self.justUpdatedKey)
    }

    /// Installs a downloaded update if no window is open. Called as one closes.
    func installIfIdle() {
        // A turn later: a window that is closing still reports itself visible.
        Task {
            guard case .ready(let release) = phase, !windowsOpen() else { return }
            await install(release, automatic: true)
        }
    }

    private func followAutoInstallSetting() {
        switch phase {
        case .available(let release) where installsAutomatically:
            Task { await stage(release) }
        case .ready(let release) where !installsAutomatically:
            phase = .available(release)
        default:
            break
        }
    }

    /// Downloads in the background ahead of an automatic install. A bundle this
    /// user can't replace is left to the Settings button, which hands over the image.
    private func stage(_ release: Release) async {
        guard case .available(release) = phase, installsAutomatically, Self.canReplaceBundle else { return }
        if staged?.release != release {
            phase = .downloading(release)
            do {
                let download = try await Self.download(release)
                discardStaged()
                staged = download
            } catch {
                phase = .failed("更新失败：\(error.localizedDescription)")
                return
            }
        }
        phase = installsAutomatically ? .ready(release) : .available(release)
        installIfIdle()
    }

    /// Swaps the release in for the running bundle and relaunches.
    func install(_ release: Release, automatic: Bool = false) async {
        if case .installing = phase { return }
        phase = .installing(release)
        let download: Download
        do {
            download = try await downloaded(release)
        } catch {
            phase = .failed("更新失败：\(error.localizedDescription)")
            return
        }

        let target = Bundle.main.bundleURL
        guard Self.canReplaceBundle else {
            // Installed somewhere this user can't write: hand over the image.
            NSWorkspace.shared.open(download.image)
            phase = .failed("没有写入 \(target.deletingLastPathComponent().path) 的权限，已打开安装包，请手动拖入")
            return
        }

        do {
            let mount = download.workspace.appending(path: "mount")
            try await Self.run("/usr/bin/hdiutil", ["attach", download.image.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
            do {
                try Self.replace(target, with: mount.appending(path: target.lastPathComponent), expecting: release.version)
            } catch {
                try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                throw error
            }
            // Awaited, not deferred: the relaunch below ends this process, and a
            // detach left to run after it never does.
            try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: download.workspace)

            if automatic { UserDefaults.standard.set(release.version, forKey: Self.justUpdatedKey) }
            relaunch(target)
        } catch {
            try? FileManager.default.removeItem(at: download.workspace)
            phase = .failed("更新失败：\(error.localizedDescription)")
        }
    }

    /// The background download when it is this release, otherwise a fresh one.
    private func downloaded(_ release: Release) async throws -> Download {
        if let staged, staged.release == release {
            self.staged = nil
            return staged
        }
        discardStaged()
        return try await Self.download(release)
    }

    private func discardStaged() {
        if let staged { try? FileManager.default.removeItem(at: staged.workspace) }
        staged = nil
    }

    private static func download(_ release: Release) async throws -> Download {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "clio-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let image = workspace.appending(path: release.assetURL.lastPathComponent)
            let (downloaded, response) = try await URLSession.shared.download(from: release.assetURL)
            try FileManager.default.moveItem(at: downloaded, to: image)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("下载失败") }

            if let expected = release.sha256 {
                let actual = SHA256.hash(data: try Data(contentsOf: image))
                    .map { String(format: "%02x", $0) }.joined()
                guard actual == expected.lowercased() else { throw UpdateError("安装包校验和不符") }
            }
            return Download(release: release, image: image, workspace: workspace)
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    private static var canReplaceBundle: Bool {
        let target = Bundle.main.bundleURL
        return FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: target.path)
    }

    /// Checks the mounted bundle is this app at the expected version, then swaps
    /// it in for the running one.
    private static func replace(_ target: URL, with incoming: URL, expecting version: String) throws {
        let info = NSDictionary(contentsOf: incoming.appending(path: "Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version
        else { throw UpdateError("安装包内容与版本不符") }

        // Copied next to the target first, so the swap is a rename on one volume.
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: target, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appending(path: target.lastPathComponent)
        try FileManager.default.copyItem(at: incoming, to: staged)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
    }

    /// A detached shell waits for this process to exit, then opens the new bundle.
    private func relaunch(_ bundle: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                          "sh", String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private static func parse(_ data: Data) throws -> Release {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:)),
              let asset = (root["assets"] as? [[String: Any]])?.first(where: {
                  ($0["name"] as? String)?.hasSuffix(".dmg") == true
              }),
              let download = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError("最新版本没有安装包") }
        let digest = (asset["digest"] as? String).flatMap { value in
            value.hasPrefix("sha256:") ? String(value.dropFirst("sha256:".count)) : nil
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, pageURL: page, assetURL: download, sha256: digest,
                       size: asset["size"] as? Int)
    }

    /// Numeric, component by component: 1.1.10 is newer than 1.1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    continuation.resume(throwing: UpdateError("\(name) 退出码 \(finished.terminationStatus)"))
                }
            }
            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
