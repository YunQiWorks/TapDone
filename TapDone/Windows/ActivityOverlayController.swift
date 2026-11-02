import AppKit
import SwiftUI
import Combine
import OSLog

private final class ActivityStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One non-activating panel, independent of the workspace and edge Dock.
@MainActor
final class ActivityOverlayController {
    private let panel: NSPanel
    let model: ActivityOverlayModel
    private let preferences: ActivityOverlayPreferences
    private let task: (RunActivity) -> QuickAction?
    private let phase: (RunActivity) -> String?
    private let image: (RunActivity) -> CGImage?
    private let details: (RunActivity) -> Void
    private let openLog: (RunActivity) -> Void
    private let stop: (RunActivity) -> Void
    private let showActivities: () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var displayID: NSNumber?
    private var installedSize = CGSize.zero
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.sidetap.SideTap", category: "ActivityOverlay")

    init(model: ActivityOverlayModel, preferences: ActivityOverlayPreferences? = nil, task: @escaping (RunActivity) -> QuickAction?,
         phase: @escaping (RunActivity) -> String?, details: @escaping (RunActivity) -> Void,
         openLog: @escaping (RunActivity) -> Void, stop: @escaping (RunActivity) -> Void,
         showActivities: @escaping () -> Void, image: @escaping (RunActivity) -> CGImage? = { _ in nil },
         windowName: String = "TapDone · 任务运行") {
        self.preferences = preferences ?? ActivityOverlayPreferences()
        self.model = model; self.task = task; self.phase = phase; self.image = image; self.details = details
        self.openLog = openLog; self.stop = stop; self.showActivities = showActivities
        panel = ActivityStatusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = windowName
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.canHide = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        model.$items.combineLatest(model.$manuallyPresented)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout() }.store(in: &subscriptions)
        self.preferences.$position.combineLatest(self.preferences.$verticalInset)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layout() }.store(in: &subscriptions)
        self.preferences.$revealRequest.dropFirst().compactMap { $0 }
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reveal() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layout() }.store(in: &subscriptions)
        layout()
    }

    /// Explicit presentation is synchronous; it does not depend on a publisher delivery.
    func reveal() { model.reveal(); layout() }
    func showCurrentState() { layout() }
    static func containsAny(_ point: NSPoint) -> Bool {
        NSApp.windows.contains { $0 is ActivityStatusPanel && $0.isVisible && $0.frame.contains(point) }
    }
    func shutdown() {
        subscriptions.removeAll(); model.shutdown(); panel.orderOut(nil); panel.close()
    }

    private func layout() {
        guard !model.items.isEmpty || model.manuallyPresented else {
            panel.orderOut(nil); displayID = nil
            logger.debug("Hidden: no visible items and no explicit presentation request")
            return
        }
        let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == displayID }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else {
            logger.error("Cannot show activity overlay: no screen available")
            return
        }
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let available = screen.visibleFrame
        let width = min(420, max(240, available.width - 32))
        let estimatedHeight = model.items.reduce(CGFloat(4)) { $0 + ($1.progress == nil ? 156 : 196) }
            + CGFloat(max(0, model.items.count - 1)) * 10
        let requestedInset = CGFloat(preferences.verticalInset)
        let bodyHeight = min(max(60, min(600, available.height - requestedInset - 100)), model.items.isEmpty ? 80 : estimatedHeight)
        let hostingView = NSHostingView(rootView: ActivityOverlayView(model: model, contentHeight: bodyHeight,
            task: task, image: image, phase: phase, details: details, openLog: openLog, stop: stop, showActivities: showActivities)
            .frame(width: width))
        // A single card uses its actual content height, without collection chrome or blank space.
        let height = model.items.count == 1 ? hostingView.fittingSize.height : bodyHeight + 84
        let size = CGSize(width: width, height: height)
        if size != installedSize {
            panel.contentView = hostingView
            installedSize = size
        }
        let x: CGFloat
        switch preferences.position {
        case .topCenter, .bottomCenter: x = available.midX - width / 2
        case .topLeft, .bottomLeft: x = available.minX + 16
        case .topRight, .bottomRight: x = available.maxX - width - 16
        }
        let inset = min(requestedInset, max(12, available.height - height - 12))
        let y = preferences.position.isTop ? available.maxY - height - inset : available.minY + inset
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        // Non-key panel: foreground its status without activating the app or keyboard focus.
        panel.alphaValue = 1
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        logger.debug("Presented: items=\(self.model.items.count, privacy: .public) visible=\(self.panel.isVisible, privacy: .public) frame=\(NSStringFromRect(self.panel.frame), privacy: .public) level=\(self.panel.level.rawValue, privacy: .public)")
    }
}
