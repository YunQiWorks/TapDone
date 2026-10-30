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
    private var gestureTimer: Timer?
    private var regionEnteredAt: TimeInterval?
    private var waitingForRegionExit = false
    private var gestureScreenFrame: NSRect?
    private var previousConfiguration = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updates.start()
        panelController = PanelController(store: store)
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
              !interactingWithSettings,
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
        store.stopAllCommands()
    }
}
