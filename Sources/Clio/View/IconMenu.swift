import SwiftUI
import AppKit

/// A footer icon button and the menu it pops, or the action it runs instead
/// when one is given.
///
/// The glyph is drawn by SwiftUI and the AppKit button sits transparently on
/// top: an `NSMenu` popped from a real view anchors and dismisses reliably in a
/// non-activating panel, while a SwiftUI glyph also renders off-screen, which
/// an AppKit control does not. The button receives the pointer, so it reports
/// hover and press for the glyph to show.
struct IconMenu: View {
    struct Item {
        let title: String
        let shortcut: String
        var isOn = false
        /// Opened from the item in place of running its action.
        var submenu: [Item] = []
        let action: () -> Void
    }

    var symbol: String
    var tint: Color
    var items: [Item] = []
    var action: (() -> Void)? = nil

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.theme) private var theme
    @Environment(\.liquidGlass) private var glass
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        let shape = glass ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isHovered ? theme.segmentedFill : .clear, in: shape)
            .liquidGlass(glass, in: shape)
            .scaleEffect(isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.08), value: isHovered)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .overlay {
                if !isSnapshot {
                    MenuTrigger(items: items,
                                action: action,
                                onHover: { isHovered = $0 },
                                onPress: { isPressed = $0 })
                }
            }
    }
}

private struct MenuTrigger: NSViewRepresentable {
    var items: [IconMenu.Item]
    var action: (() -> Void)?
    var onHover: (Bool) -> Void
    var onPress: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingButton {
        let button = TrackingButton(title: "", target: context.coordinator, action: #selector(Coordinator.present(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.setButtonType(.momentaryChange)
        return button
    }

    func updateNSView(_ view: TrackingButton, context: Context) {
        context.coordinator.items = items
        context.coordinator.action = action
        view.onHover = onHover
        view.onPress = onPress
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    final class Coordinator: NSObject {
        var items: [IconMenu.Item]
        var action: (() -> Void)?
        /// The open menu's actions, indexed by each entry's tag.
        private var actions: [() -> Void] = []

        init(items: [IconMenu.Item]) {
            self.items = items
        }

        @objc func present(_ sender: NSButton) {
            let button = sender as? TrackingButton
            button?.onPress?(false)
            if let action {
                action()
                return
            }
            let menu = NSMenu()
            actions = []
            add(items, to: menu)
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height + 4),
                       in: sender)
            // The menu swallows the exit event when the pointer leaves while it
            // is open.
            button?.syncHover()
        }

        private func add(_ items: [IconMenu.Item], to menu: NSMenu) {
            for item in items {
                if item.title.isEmpty {
                    menu.addItem(.separator())
                    continue
                }
                let entry = NSMenuItem(title: item.title,
                                       action: item.submenu.isEmpty ? #selector(fire(_:)) : nil,
                                       keyEquivalent: item.shortcut)
                entry.keyEquivalentModifierMask = item.shortcut.isEmpty ? [] : [.command]
                entry.target = self
                entry.state = item.isOn ? .on : .off
                if item.submenu.isEmpty {
                    entry.tag = actions.count
                    actions.append(item.action)
                } else {
                    let submenu = NSMenu()
                    add(item.submenu, to: submenu)
                    entry.submenu = submenu
                }
                menu.addItem(entry)
            }
        }

        @objc private func fire(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }
}

private final class TrackingButton: NSButton {
    var onHover: ((Bool) -> Void)?
    var onPress: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(true)
        // Returns once the button is released, after any menu it opened closes.
        super.mouseDown(with: event)
        onPress?(false)
    }

    func syncHover() {
        guard let window else { return }
        onHover?(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }
}
