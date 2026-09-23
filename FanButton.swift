import AppKit
import SwiftUI

@main
final class FanButton: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = FanModel()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var widget: NSPanel?
    private let widgetOpenKey = "widgetOpen"

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = FanButton()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "Fan control")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)

        let panel = NSHostingController(rootView: PanelView(model: model) { [weak self] in self?.showWidget() })
        panel.sizingOptions = .preferredContentSize
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.delegate = self

        if UserDefaults.standard.bool(forKey: widgetOpenKey) { showWidget() }
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) { model.startWatching() }
    func popoverDidClose(_ notification: Notification) { model.stopWatching() }

    private func showWidget() {
        popover.performClose(nil)
        UserDefaults.standard.set(true, forKey: widgetOpenKey)
        if let widget { widget.orderFrontRegardless(); return }

        let content = NSHostingController(rootView: WidgetView(model: model) { [weak self] in self?.closeWidget() })
        content.sizingOptions = .preferredContentSize
        let panel = NSPanel(contentViewController: content)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Restores the spot it was dragged to last time; the first time, start near the top-right.
        if !panel.setFrameUsingName("FanButtonWidget"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 250, y: screen.maxY - 20))
        }
        panel.setFrameAutosaveName("FanButtonWidget")
        panel.orderFrontRegardless()
        widget = panel
        model.startWatching()
    }

    private func closeWidget() {
        UserDefaults.standard.set(false, forKey: widgetOpenKey)
        widget?.close()
        widget = nil
        model.stopWatching()
    }
}
