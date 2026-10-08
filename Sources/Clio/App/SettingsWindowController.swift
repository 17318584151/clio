import AppKit
import SwiftUI
import Combine

/// The standalone settings window.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private let store: UsageStore
    private let prefs: Preferences
    private let onPreviewConfetti: () -> Void
    var onClose: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    init(store: UsageStore, prefs: Preferences, onPreviewConfetti: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        self.onPreviewConfetti = onPreviewConfetti
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            let root = SettingsView(onPreviewConfetti: onPreviewConfetti)
                .environmentObject(store)
                .environmentObject(prefs)
            window.contentView = NSHostingView(rootView: root)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        // Liquid Glass shows what is behind the window only through a clear
        // one. The title bar turns clear with it; the settings view fades its
        // rows out before they reach the bar.
        prefs.$liquidGlass
            .removeDuplicates()
            .sink { [weak window] isOn in
                guard let window else { return }
                let glass = isOn && LiquidGlass.isAvailable
                window.isOpaque = !glass
                window.backgroundColor = glass ? .clear : .windowBackgroundColor
                window.titlebarAppearsTransparent = glass
                window.invalidateShadow()
            }
            .store(in: &cancellables)
        _ = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: window,
                                                   queue: .main) { [weak self] _ in
            Task { @MainActor in
                // A closed window's view keeps its animations running, so it
                // is dropped here and rebuilt on the next open.
                self?.window?.contentView = nil
                self?.onClose?()
            }
        }
        return window
    }
}
