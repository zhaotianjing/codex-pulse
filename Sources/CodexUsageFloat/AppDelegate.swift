import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var panelController: FloatingPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panelController = FloatingPanelController(store: store)
        self.panelController = panelController
        configureStatusItem()

        panelController.show()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.expandAndShow()
        return true
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "chart.bar.xaxis",
                accessibilityDescription: "Codex 用量"
            )
            button.toolTip = "Codex 用量"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏悬浮窗", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex Pulse", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }

        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        panelController?.toggle()
    }

    @objc private func refresh() {
        panelController?.expandAndShow()
        store.refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
