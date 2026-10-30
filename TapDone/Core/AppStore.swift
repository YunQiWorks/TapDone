import AppKit
import Combine
import SwiftUI

enum ActivationEdge: String, CaseIterable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return "左边缘"
        case .right: return "右边缘"
        case .top: return "上边缘"
        case .bottom: return "下边缘"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
    var horizontalDock: Bool { self == .top || self == .bottom }
    var dockOnLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }

    func contains(_ point: NSPoint, screen: NSRect, range: CGFloat) -> Bool {
        guard screen.contains(point) else { return false }
        let left = point.x <= screen.minX + range
        let right = point.x >= screen.maxX - range
        let top = point.y >= screen.maxY - range
        let bottom = point.y <= screen.minY + range
        switch self {
        case .left: return left
        case .right: return right
        case .top: return top
        case .bottom: return bottom
        case .topLeft: return top && left
        case .topRight: return top && right
        case .bottomLeft: return bottom && left
        case .bottomRight: return bottom && right
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var library = TaskLibrary()
    @Published private(set) var storageError = ""
    var categories: [TaskCategory] { library.categories }
    var actions: [QuickAction] { library.actions }
    var libraryURL: URL { repository.libraryURL }
    var cliURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tapdone") }
    var dockActions: [QuickAction] {
        let pinned = Set(library.dockTaskIDs)
        return actions.filter { pinned.contains($0.id) }
    }
    func isInDock(_ id: String) -> Bool { library.dockTaskIDs.contains(id) }
    @Published var message = ""
    @Published var updateInstallationPending = false
    var runningCommandCount: Int { execution.localExecutionCount }
    @Published private(set) var commandRuns: [CommandRun] = []
    let execution = TaskExecutionCoordinator()
    lazy var workflows = WorkflowRunner(execution: execution)
    lazy var activities = RunActivityCenter(execution: execution, workflows: workflows)
    private var runSubscription: AnyCancellable?
    @Published var gestureEnabled: Bool { didSet { defaults.set(gestureEnabled, forKey: "gestureEnabled") } }
    @Published var activationEdge: ActivationEdge { didSet { defaults.set(activationEdge.rawValue, forKey: "activationEdge") } }
    @Published var edgeRange: Double { didSet { defaults.set(edgeRange, forKey: "edgeRange") } }
    @Published var dwellTime: Double { didSet { defaults.set(dwellTime, forKey: "dwellTime") } }
    private let defaults: UserDefaults
    private let repository: TaskRepository
    private var libraryWatcher: DispatchSourceFileSystemObject?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        repository = TaskRepository(legacyDefaults: defaults)
        defaults.register(defaults: ["gestureEnabled": true, "edgeRange": 12.0, "dwellTime": 0.4])
        gestureEnabled = defaults.bool(forKey: "gestureEnabled")
        let edgeValue = defaults.string(forKey: "activationEdge") ?? defaults.string(forKey: "gestureDirection") ?? "left"
        activationEdge = ActivationEdge(rawValue: edgeValue) ?? .left
        let range = defaults.double(forKey: "edgeRange")
        edgeRange = range.isFinite ? min(max(range, 2), 120) : 12
        let dwell = defaults.double(forKey: "dwellTime")
        dwellTime = dwell.isFinite ? min(max(dwell, 0.1), 2) : 0.4
        do { library = try repository.read(createIfMissing: true) }
        catch { storageError = error.localizedDescription }
        do { commandRuns = try execution.restore { [weak self] run in self?.receiveRun(run) } }
        catch { storageError = "运行记录恢复失败：\(error.localizedDescription)" }
        workflows.canStart = { [weak self] in !(self?.updateInstallationPending ?? true) }
        workflows.restore()
        _ = activities
        runSubscription = execution.$runs.sink { [weak self] in self?.commandRuns = $0 }
        watchLibrary()
    }

    deinit { libraryWatcher?.cancel() }

    private func watchLibrary() {
        // Watch the directory rather than library.json: atomic saves replace the inode.
        let descriptor = open(repository.directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.refreshLibrary() }
        }
        source.setCancelHandler { close(descriptor) }
        libraryWatcher = source
        source.resume()
    }

    func refreshLibrary() {
        do {
            let latest = try repository.read()
            if latest != library { library = latest }
            storageError = ""
        } catch { storageError = error.localizedDescription }
    }

    @discardableResult
    private func modify(expectedRevision: UInt64? = nil, _ change: (inout TaskLibrary) throws -> Void) -> Bool {
        do {
            library = try repository.transaction(expectedRevision: expectedRevision, change)
            storageError = ""
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    func importTasks(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 16 * 1024 * 1024 else { throw TapDoneError("INPUT_TOO_LARGE", "输入文件不能超过 16 MB。") }
            let documents = try TaskDocument.decode(data)
            var result = ApplyResult()
            if modify({ result = try $0.apply(documents) }) {
                message = "已添加 \(result.created.count) 个任务，更新 \(result.updated.count) 个任务。"
            }
        } catch { storageError = error.localizedDescription }
    }

    func categoryID(for taskID: String) -> String? {
        categories.first { $0.tasks.contains { $0.id == taskID } }?.id
    }

    func saveCategory(id: String?, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        modify { next in
            guard !next.categories.contains(where: { $0.id != id && $0.name == name }) else {
                throw TapDoneError("DUPLICATE_CATEGORY", "分类名称已存在。")
            }
            if let id {
                guard let index = next.categories.firstIndex(where: { $0.id == id }) else { throw TapDoneError("CATEGORY_NOT_FOUND", "分类已被移除。") }
                next.categories[index].name = name
            } else { next.categories.append(TaskCategory(id: UUID().uuidString, name: name)) }
        }
    }

    func deleteCategory(_ id: String) {
        modify { next in
            let removed = Set(next.categories.first(where: { $0.id == id })?.tasks.map(\.id) ?? [])
            next.categories.removeAll { $0.id == id }
            next.dockTaskIDs.removeAll { removed.contains($0) }
        }
    }

    func moveCategory(_ id: String, by offset: Int) {
        modify { next in
            guard let index = next.categories.firstIndex(where: { $0.id == id }),
                  next.categories.indices.contains(index + offset) else { return }
            next.categories.swapAt(index, index + offset)
        }
    }

    @discardableResult
    func save(_ action: QuickAction, categoryID: String, inDock: Bool, expectedRevision: UInt64) -> Bool {
        modify(expectedRevision: expectedRevision) { next in
            guard let destination = next.categories.firstIndex(where: { $0.id == categoryID }) else {
                throw TapDoneError("CATEGORY_NOT_FOUND", "分类已被移除，请重新选择。")
            }
            let oldIndex = next.categories[destination].tasks.firstIndex { $0.id == action.id }
            for index in next.categories.indices { next.categories[index].tasks.removeAll { $0.id == action.id } }
            next.categories[destination].tasks.insert(action, at: oldIndex ?? next.categories[destination].tasks.count)
            if inDock {
                if !next.dockTaskIDs.contains(action.id) { next.dockTaskIDs.append(action.id) }
            } else { next.dockTaskIDs.removeAll { $0 == action.id } }
        }
    }

    func setInDock(_ id: String, enabled: Bool) {
        modify { next in
            guard next.actions.contains(where: { $0.id == id }) else { throw TapDoneError("TASK_NOT_FOUND", "任务已被移除。") }
            if enabled {
                if !next.dockTaskIDs.contains(id) { next.dockTaskIDs.append(id) }
            } else { next.dockTaskIDs.removeAll { $0 == id } }
        }
    }

    func deleteTask(_ id: String) {
        modify { next in
            for index in next.categories.indices { next.categories[index].tasks.removeAll { $0.id == id } }
            next.dockTaskIDs.removeAll { $0 == id }
        }
    }

    func move(_ id: String, by offset: Int) {
        modify { next in
            guard let category = next.categories.firstIndex(where: { $0.tasks.contains { $0.id == id } }),
                  let index = next.categories[category].tasks.firstIndex(where: { $0.id == id }),
                  next.categories[category].tasks.indices.contains(index + offset) else { return }
            next.categories[category].tasks.swapAt(index, index + offset)
        }
    }

    private func receiveRun(_ run: TaskRun) {
        guard let index = commandRuns.firstIndex(where: { $0.id == run.id }) else { return }
        commandRuns[index] = run
        message = "“\(run.title)”\(run.state.title)"
        if let error = execution.persistenceError { storageError = error }
    }

    func stopCommand(_ runID: String) { execution.stop(runID) }
    func stopAllCommands() { workflows.suspendAll(); execution.stopAll() }

    func run(_ action: QuickAction) {
        guard !updateInstallationPending else {
            message = "更新正在等待安装，暂时无法启动新任务。"
            return
        }
        guard !commandRuns.contains(where: { $0.taskID == action.id && !$0.state.isTerminal }) else {
            message = "“\(action.title)”正在运行，请在运行记录中查看。"
            return
        }
        do {
            let run = try execution.start(action) { [weak self] completed in self?.receiveRun(completed) }
            receiveRun(run)
            message = "已开始“\(action.title)”，可在运行记录中查看。"
        } catch {
            if let restored = try? execution.history.load() { commandRuns = restored }
            message = "无法启动“\(action.title)”：\(error.localizedDescription)"
            let alert = NSAlert()
            alert.messageText = "任务启动失败"
            alert.informativeText = message
            alert.runModal()
        }
    }
}
