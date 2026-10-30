import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    @Published private(set) var isConfigured = false
    @Published private(set) var canCheck = false
    @Published private(set) var status = "更新功能尚未启动。"
    @Published private(set) var lastCheck: Date?
    @Published private(set) var installationPending = false
    @Published var automaticChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    let releaseURL = URL(string: "https://github.com/YunQiWorks/TapDone/releases")!
    let feedURLString: String
    let currentVersion: String
    private weak var store: AppStore?
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
    private var installHandler: (() -> Void)?
    private var waitingForTerminationReply = false
    private var backupPrepared = false

    init(store: AppStore) {
        self.store = store
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        currentVersion = "\(version) (\(build))"
        feedURLString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        super.init()
        store.$commandRuns.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resumeInstallationIfIdle() }
        }.store(in: &subscriptions)
    }

    func start() {
        guard controller == nil else { return }
        guard let feed = URL(string: feedURLString), feed.scheme == "https", feed.host != nil else {
            status = "发布者尚未配置有效的 HTTPS 更新地址。"
            return
        }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard let bytes = Data(base64Encoded: key), bytes.count == 32 else {
            status = "发布者尚未配置更新签名公钥，当前可从 GitHub Releases 获取版本。"
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            automaticChecks = controller.updater.automaticallyChecksForUpdates
            try controller.updater.start()
            isConfigured = true
            lastCheck = controller.updater.lastUpdateCheckDate
            status = "自动检查更新，下载和安装由你确认。"
            controller.updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
                .receive(on: RunLoop.main)
                .sink { [weak self] allowed in self?.canCheck = allowed }
                .store(in: &subscriptions)
        } catch {
            self.controller = nil
            status = "无法启动更新功能：\(error.localizedDescription)"
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let controller, isConfigured else {
            let alert = NSAlert(); alert.messageText = "暂时无法检查更新"
            alert.informativeText = status; alert.runModal()
            return
        }
        guard canCheck else { return }
        status = "正在检查更新…"
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "发现新版本 \(item.displayVersionString)，请在更新窗口确认。"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        lastCheck = updater.lastUpdateCheckDate
        status = "当前没有适用于此版本的新更新。"
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        beginInstallation()
    }

    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        beginInstallation()
        installHandler = handler
        DispatchQueue.main.async { [weak self] in self?.resumeInstallationIfIdle() }
        return true
    }

    private func beginInstallation() {
        installationPending = true
        store?.updateInstallationPending = true
        let count = store?.runningCommandCount ?? 0
        status = count > 0 ? "更新已就绪，等待 \(count) 个任务完成后安装。" : "更新已就绪，正在准备安装。"
    }

    private func prepareBackup() throws {
        guard !backupPrepared else { return }
        _ = try TaskRepository().backupForApplicationUpdate()
        backupPrepared = true
    }

    func resumeInstallationIfIdle() {
        guard installationPending else { return }
        let count = store?.runningCommandCount ?? 0
        guard count == 0 else {
            status = "更新已就绪，等待 \(count) 个任务完成后安装。"
            return
        }
        do { try prepareBackup() }
        catch {
            status = "任务库备份失败，已延后安装：\(error.localizedDescription)"
            return
        }
        if waitingForTerminationReply {
            waitingForTerminationReply = false
            status = "正在安装更新并重新启动…"
            NSApp.reply(toApplicationShouldTerminate: true)
        } else if let handler = installHandler {
            installHandler = nil
            status = "正在安装更新并重新启动…"
            handler()
        }
    }

    /// A termination gate also covers Sparkle paths that skip the postponement delegate.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard installationPending else { return .terminateNow }
        if (store?.runningCommandCount ?? 0) > 0 {
            waitingForTerminationReply = true
            return .terminateLater
        }
        do { try prepareBackup(); return .terminateNow }
        catch {
            status = "任务库备份失败，已取消本次安装：\(error.localizedDescription)"
            return .terminateCancel
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearInstallation()
        lastCheck = updater.lastUpdateCheckDate
        let failure = error as NSError
        // SUNoUpdateError is informational, and is also sent through the abort delegate.
        status = failure.code == 1001 && failure.domain == SUSparkleErrorDomain
            ? "当前没有适用于此版本的新更新。" : "更新未完成：\(error.localizedDescription)"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastCheck = updater.lastUpdateCheckDate
        if let error { self.updater(updater, didAbortWithError: error) }
    }

    private func clearInstallation() {
        if waitingForTerminationReply { NSApp.reply(toApplicationShouldTerminate: false) }
        waitingForTerminationReply = false
        installHandler = nil
        installationPending = false
        store?.updateInstallationPending = false
        backupPrepared = false
    }
}
