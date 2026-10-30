import AppKit
import SwiftUI
import QuartzCore

final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class PanelController {
    private let panel: QuickPanel
    private let store: AppStore
    private let namePanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var shownAt = Date.distantPast
    private var outsideSince: Date?
    var isVisible: Bool { panel.isVisible }

    init(store: AppStore) {
        self.store = store
        panel = QuickPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        namePanel.isReleasedWhenClosed = false
        namePanel.isOpaque = false
        namePanel.backgroundColor = .clear
        namePanel.hasShadow = true
        namePanel.ignoresMouseEvents = true
        namePanel.level = .floating
        namePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.addChildWindow(namePanel, ordered: .above)
        installContent()
    }

    private func installContent() {
        panel.contentView = NSHostingView(rootView: SidebarView(store: store, dismiss: { [weak self] in
            self?.hide()
        }, showName: { [weak self] action, frame in
            self?.updateName(action, buttonFrame: frame)
        }))
    }

    func show(on screen: NSScreen) {
        guard !store.dockActions.isEmpty else { return }
        namePanel.orderOut(nil)
        installContent()
        let visible = screen.visibleFrame.insetBy(dx: 0, dy: 8)
        let edge = store.activationEdge
        let background = DockMetrics.backgroundSize(count: store.dockActions.count, horizontal: edge.horizontalDock)
        let width = min(background.width + DockMetrics.shadowInset * 2, visible.width)
        let height = min(background.height + DockMetrics.shadowInset * 2, visible.height)
        let x: CGFloat
        let y: CGFloat
        if edge.horizontalDock {
            x = visible.midX - width / 2
            y = edge == .top ? visible.maxY - height : visible.minY
        } else {
            x = edge.dockOnLeft ? screen.frame.minX + 6 : screen.frame.maxX - width - 6
            switch edge {
            case .topLeft, .topRight: y = visible.maxY - height
            case .bottomLeft, .bottomRight: y = visible.minY
            default: y = visible.midY - height / 2
            }
        }
        let target = NSRect(x: x, y: y, width: width, height: height)
        let start = edge.horizontalDock
            ? target.offsetBy(dx: 0, dy: edge == .top ? height : -height)
            : target.offsetBy(dx: edge.dockOnLeft ? -width : width, dy: 0)
        panel.setFrame(start, display: false)
        shownAt = Date()
        outsideSince = nil
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        namePanel.orderOut(nil)
        panel.orderOut(nil)
        outsideSince = nil
    }

    private func updateName(_ action: QuickAction?, buttonFrame: CGRect?) {
        guard panel.isVisible, let action, let buttonFrame,
              let screen = panel.screen else {
            namePanel.orderOut(nil)
            return
        }
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = (action.title as NSString).size(withAttributes: [.font: font]).width
        let width = min(max(textWidth + 28, 48), 280)
        let height: CGFloat = 34
        let label = Text(action.title)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(width: width, height: height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
        namePanel.contentView = NSHostingView(rootView: label)
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let edge = store.activationEdge
        let centerY = panel.frame.maxY - buttonFrame.midY
        let centerX = panel.frame.minX + buttonFrame.midX
        let preferredX = edge.horizontalDock ? centerX - width / 2
            : edge.dockOnLeft ? panel.frame.maxX + 8 : panel.frame.minX - width - 8
        let preferredY = edge.horizontalDock
            ? (edge == .top ? panel.frame.minY - height - 8 : panel.frame.maxY + 8)
            : centerY - height / 2
        let x = max(visible.minX, min(preferredX, visible.maxX - width))
        let y = max(visible.minY, min(preferredY, visible.maxY - height))
        namePanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        namePanel.orderFrontRegardless()
    }

    func updateAutoHide(at point: NSPoint, now: Date) {
        guard panel.isVisible else { return }
        if panel.frame.insetBy(dx: -28, dy: -20).contains(point) {
            outsideSince = nil
        } else if now.timeIntervalSince(shownAt) > 0.8 {
            if let since = outsideSince {
                if now.timeIntervalSince(since) >= 0.5 { hide() }
            } else { outsideSince = now }
        }
    }
}
