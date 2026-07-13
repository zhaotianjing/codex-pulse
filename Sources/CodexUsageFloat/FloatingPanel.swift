import AppKit
import SwiftUI

final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FloatingPanelController: NSWindowController {
    private static let expandedSize = NSSize(width: 356, height: 458)
    private static let collapsedSize = NSSize(width: 236, height: 66)

    private let panel: UsagePanel
    private let store: UsageStore
    private var isCollapsed = false

    init(store: UsageStore) {
        self.store = store
        let size = Self.expandedSize
        panel = UsagePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(size)
        panel.minSize = Self.collapsedSize
        panel.maxSize = Self.expandedSize

        installExpandedView()

        let restored = panel.setFrameUsingName("CodexUsageFloatPanel")
        panel.setFrameAutosaveName("CodexUsageFloatPanel")
        if restored {
            let restoredFrame = panel.frame
            panel.setFrame(
                NSRect(
                    x: restoredFrame.maxX - size.width,
                    y: restoredFrame.maxY - size.height,
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
        } else {
            positionAtTopRight()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func expandAndShow() {
        expand()
        show()
    }

    func toggle() {
        panel.isVisible ? panel.orderOut(nil) : show()
    }

    private func collapse() {
        guard !isCollapsed else { return }
        isCollapsed = true

        let rootView = CompactUsageView(
            store: store,
            onExpand: { [weak self] in self?.expand() },
            onQuit: { NSApp.terminate(nil) }
        )
        panel.contentView = NSHostingView(rootView: rootView)
        resize(to: Self.collapsedSize, animated: true)
    }

    private func expand() {
        guard isCollapsed else { return }
        isCollapsed = false
        installExpandedView()
        resize(to: Self.expandedSize, animated: true)
    }

    private func installExpandedView() {
        let rootView = UsageView(
            store: store,
            onCollapse: { [weak self] in self?.collapse() },
            onQuit: { NSApp.terminate(nil) }
        )
        panel.contentView = NSHostingView(rootView: rootView)
    }

    private func resize(to size: NSSize, animated: Bool) {
        let current = panel.frame
        let target = NSRect(
            x: current.maxX - size.width,
            y: current.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(target, display: true, animate: animated)
    }

    private func positionAtTopRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - 22,
            y: visible.maxY - panel.frame.height - 22
        )
        panel.setFrameOrigin(origin)
    }
}
