import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = AppStore()
    lazy var updates = AppUpdateController(store: store)
    private var librarySubscription: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var taskMenuIsOpen = false
    private var panelController: PanelController?
    private var settingsWindow: NSWindow?
    private var activityOverlay: ActivityOverlayController?
    private var gestureTimer: Timer?
    private var regionEnteredAt: TimeInterval?
    private var waitingForRegionExit = false
    private var gestureScreenFrame: NSRect?
    private var previousConfiguration = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureApplicationMenu()
        updates.start()
        panelController = PanelController(store: store)
        activityOverlay = ActivityOverlayController(model: ActivityOverlayModel(center: store.activities), preferences: store.overlayPreferences,
            task: { [weak self] activity in self?.store.commandRuns.first(where: { $0.id == activity.runID })?.definition },
            phase: { [weak self] activity in self?.currentPhase(for: activity) },
            details: { [weak self] activity in self?.showActivityDetails(activity) },
            openLog: { [weak self] activity in self?.openActivityLog(activity) },
            stop: { [weak self] activity in
                if activity.source == .workflow { self?.store.workflows.stop(activity.runID) }
                else { self?.store.stopCommand(activity.runID) }
            }, showActivities: { [weak self] in self?.showActivities() })
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuBarIcon = NSImage(named: "MenuBarIcon")
        menuBarIcon?.isTemplate = true
        menuBarIcon?.size = NSSize(width: 18, height: 18)
        menuBarIcon?.accessibilityDescription = "TapDone"
        item.button?.image = menuBarIcon
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildTaskMenu(menu)
        librarySubscription = store.$library.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.panelController?.hide()
                self?.resetGesture()
            }
        }
        showSettings()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleGesture() }
        }
        timer.tolerance = 0.003
        RunLoop.main.add(timer, forMode: .common)
        gestureTimer = timer
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func configureApplicationMenu() {
        // Preserve native editing shortcuts without registering a SwiftUI Settings scene.
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "TapDone")
        let workspace = applicationMenu.addItem(withTitle: "显示 TapDone", action: #selector(showSettings), keyEquivalent: ",")
        workspace.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出 TapDone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        rebuildTaskMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        taskMenuIsOpen = true
        panelController?.hide()
        resetGesture()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        taskMenuIsOpen = false
        resetGesture()
    }

    private func rebuildTaskMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let activity = menu.addItem(withTitle: "任务运行状态…", action: #selector(showActivityOverlay), keyEquivalent: "")
        activity.target = self
        let update = menu.addItem(withTitle: "检查更新…", action: #selector(AppUpdateController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updates
        update.isEnabled = updates.canCheck
        menu.addItem(.separator())
        if store.categories.isEmpty {
            let empty = menu.addItem(withTitle: "暂无任务，请在设置中添加", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for category in store.categories {
            let group = menu.addItem(withTitle: category.name, action: nil, keyEquivalent: "")
            group.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let submenu = NSMenu(title: category.name)
            if category.tasks.isEmpty {
                let empty = submenu.addItem(withTitle: "暂无子任务", action: nil, keyEquivalent: "")
                empty.isEnabled = false
            }
            for task in category.tasks {
                let entry = submenu.addItem(withTitle: task.title, action: #selector(runMenuTask(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = task.id
                entry.toolTip = task.target
                if let image = TaskIconProvider.image(for: task) {
                    entry.image = NSImage(cgImage: image, size: NSSize(width: 18, height: 18))
                } else {
                    entry.image = NSImage(systemSymbolName: task.symbol, accessibilityDescription: nil)
                }
            }
            group.submenu = submenu
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TapDone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func runMenuTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let task = store.actions.first(where: { $0.id == id }) else { return }
        panelController?.hide()
        resetGesture()
        store.run(task)
    }

    @objc private func showActivityOverlay() { activityOverlay?.reveal() }

    private func showActivities() {
        store.workspaceOpenRequest = .init(destination: .activities)
        showSettings()
    }

    private func showActivityDetails(_ activity: RunActivity) {
        store.workspaceOpenRequest = .init(destination: activity.source == .workflow ? .workflow(activity.runID) : .task(activity.definitionID))
        showSettings()
    }

    private func openActivityLog(_ activity: RunActivity) {
        do {
            let url = try store.execution.history.read(activity.runID).logURL
            guard FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
                throw TapDoneError("LOG_UNAVAILABLE", "日志文件不存在或无法打开，请在运行记录中检查。")
            }
        }
        catch { store.message = "无法打开日志：\(error.localizedDescription)"; showActivities() }
    }

    private func currentPhase(for activity: RunActivity) -> String? {
        guard activity.source == .workflow, let run = store.workflows.runs.first(where: { $0.id == activity.runID }),
              let node = run.nodes.first(where: { $0.state == .waitingReview || $0.state == .running || $0.state == .starting || $0.state == .failed }),
              let name = run.plan.definition.nodes.first(where: { $0.id == node.id })?.name else { return nil }
        return "当前节点：" + name
    }

    @objc private func showSettings() {
        panelController?.hide()
        resetGesture()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "TapDone"
            window.contentMinSize = NSSize(width: 820, height: 600)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store, updates: updates))
            if !window.setFrameUsingName("TapDoneWorkspace") { window.center() }
            window.setFrameAutosaveName("TapDoneWorkspace")
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func resetGesture() {
        regionEnteredAt = nil
        gestureScreenFrame = nil
    }

    private func sampleGesture() {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let point = NSEvent.mouseLocation
        panelController?.updateAutoHide(at: point, now: now)
        let configuration = "\(store.gestureEnabled)-\(store.activationEdge)-\(store.edgeRange)-\(store.dwellTime)"
        if configuration != previousConfiguration {
            previousConfiguration = configuration
            waitingForRegionExit = false
            panelController?.hide()
            resetGesture()
        }
        let interactingWithSettings = settingsWindow.map {
            $0.isVisible && $0.isKeyWindow && $0.frame.contains(point)
        } ?? false
        guard store.gestureEnabled, !taskMenuIsOpen, NSEvent.pressedMouseButtons == 0,
              !interactingWithSettings, !ActivityOverlayController.containsAny(point),
              !store.dockActions.isEmpty else {
            resetGesture()
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            resetGesture()
            return
        }
        if gestureScreenFrame != screen.frame {
            waitingForRegionExit = false
            resetGesture()
            gestureScreenFrame = screen.frame
        }
        guard store.activationEdge.contains(point, screen: screen.frame, range: CGFloat(store.edgeRange)) else {
            regionEnteredAt = nil
            waitingForRegionExit = false
            return
        }
        guard panelController?.isVisible != true else { regionEnteredAt = nil; return }
        guard !waitingForRegionExit else { return }
        if let entered = regionEnteredAt {
            if uptime - entered >= store.dwellTime {
                panelController?.show(on: screen)
                waitingForRegionExit = true
                regionEnteredAt = nil
            }
        } else {
            regionEnteredAt = uptime
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updates.applicationShouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        gestureTimer?.invalidate()
        activityOverlay?.shutdown()
        store.stopAllCommands()
    }
}
