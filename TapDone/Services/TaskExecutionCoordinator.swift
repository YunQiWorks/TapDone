import AppKit
import Combine

/// Sole application entry point for task execution; UI surfaces consume TaskRun.
/// Native opening and process execution share history, identity and completion rules.
@MainActor
final class TaskExecutionCoordinator: ObservableObject {
    private struct NativeJob {
        var run: TaskRun
        let task: Task<Void, Never>
        let completion: (TaskRun) -> Void
    }
    let history: TaskRunRepository
    private let commands: CommandRunner
    private let asynchronous: RemoteAsyncRunner
    private let opener = ActionExecutor()
    private var activeTasks: [String: String] = [:]
    private var activeStates: [String: TaskRun.State] = [:]
    @Published private(set) var localExecutionCount = 0
    @Published private(set) var runs: [TaskRun] = []
    func isTaskActive(_ id: String) -> Bool { activeTasks[id] != nil }
    private var nativeJobs: [String: NativeJob] = [:]
    private var nativePersistenceError: String?
    var persistenceError: String? { nativePersistenceError ?? asynchronous.persistenceError ?? commands.persistenceError }

    init(history: TaskRunRepository = TaskRunRepository()) {
        self.history = history
        commands = CommandRunner(history: history)
        asynchronous = RemoteAsyncRunner(history: history)
    }

    func restore(update: @escaping (TaskRun) -> Void) throws -> [TaskRun] {
        var runs = try history.recover()
        self.runs = runs
        for index in runs.indices where runs[index].state == .waitingExternal {
            do { try asynchronous.resume(runs[index]) { [weak self] run in self?.track(run); update(run) } }
            catch {
                try runs[index].complete(state: .interrupted, exitCode: nil,
                    summary: "无法恢复远程查询：\(error.localizedDescription)。不会重新提交。")
                try history.save(runs[index])
            }
        }
        for run in runs where !run.state.isTerminal { track(run) }
        self.runs = runs
        return runs
    }

    private func track(_ run: TaskRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index] = run }
        else { runs.insert(run, at: 0) }
        if run.state.isTerminal {
            activeStates.removeValue(forKey: run.id)
            if activeTasks[run.taskID] == run.id { activeTasks.removeValue(forKey: run.taskID) }
        } else { activeTasks[run.taskID] = run.id; activeStates[run.id] = run.state }
        localExecutionCount = activeStates.values.filter { $0 == .running }.count
    }
    private func remember(_ run: TaskRun) -> TaskRun { track(run); return run }

    func start(_ action: QuickAction, completion: @escaping (TaskRun) -> Void) throws -> TaskRun {
        do { return try startImpl(action, completion: completion) }
        catch {
            // A failed spawn can already have a durable failure record.
            if let saved = try? history.load() { runs = saved }
            throw error
        }
    }

    private func startImpl(_ action: QuickAction, completion: @escaping (TaskRun) -> Void) throws -> TaskRun {
        guard activeTasks[action.id] == nil else { throw TapDoneError("TASK_ALREADY_RUNNING", "该任务正在执行或等待远程结果，不能重复启动。") }
        let completed: (TaskRun) -> Void = { [weak self] run in self?.track(run); completion(run) }
        if action.kind == .external, action.externalProgram?.asyncOptions != nil {
            return remember(try asynchronous.start(action, update: completed))
        }
        if action.kind == .command || action.kind == .external {
            return remember(try commands.start(action, completion: completed))
        }
        let id = UUID().uuidString
        let logs = history.directoryURL.deletingLastPathComponent().appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let log = logs.appendingPathComponent(id + ".log")
        guard FileManager.default.createFile(atPath: log.path,
                  contents: Data("TapDone · \(action.title)\n正在请求系统打开目标。\n".utf8),
                  attributes: [.posixPermissions: 0o600]) else {
            throw TapDoneError("RUN_STORAGE_FAILED", "无法创建任务日志，未执行打开操作。")
        }
        let run = TaskRun(id: id, definition: action, logURL: log)
        // Persist before invoking the OS, so missing history never hides side effects.
        try history.save(run)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.opener.execute(action)
                self.finishNative(id, error: nil)
            } catch {
                self.finishNative(id, error: error)
            }
        }
        nativeJobs[id] = NativeJob(run: run, task: task, completion: completed)
        return remember(run)
    }

    func stop(_ id: String) {
        if asynchronous.contains(id) { asynchronous.stop(id) } else { commands.stop(id) }
    }

    func stopAll() {
        asynchronous.suspendAll()
        commands.stopAll()
        // An OS opening request cannot be recalled. Do not claim cancellation succeeded.
        for id in Array(nativeJobs.keys) {
            guard var job = nativeJobs.removeValue(forKey: id) else { continue }
            job.task.cancel()
            do {
                try job.run.complete(state: .interrupted, exitCode: nil,
                    summary: "应用退出，未确认系统打开请求的最终结果；请求可能已经生效。")
                persist(job.run)
            } catch { nativePersistenceError = error.localizedDescription }
            job.completion(job.run)
        }
    }

    private func finishNative(_ id: String, error: Error?) {
        // Removed jobs and late callbacks cannot overwrite terminal records.
        guard var job = nativeJobs.removeValue(forKey: id) else { return }
        let message = error.map { "系统打开请求失败：\($0.localizedDescription)" }
            ?? "系统已接受打开请求；不代表目标应用或后续业务操作已完成。"
        do {
            try job.run.complete(state: error == nil ? .succeeded : .failed, exitCode: nil,
                                 summary: message, output: .object(["systemAccepted": .bool(error == nil)]))
            persist(job.run)
        } catch { nativePersistenceError = error.localizedDescription }
        if let handle = try? FileHandle(forWritingTo: job.run.logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((message + "\n").utf8))
        }
        job.completion(job.run)
    }

    private func persist(_ run: TaskRun) {
        do { try history.save(run); nativePersistenceError = nil }
        catch { nativePersistenceError = "运行记录保存失败：\(error.localizedDescription)" }
    }
}

/// Presentation adapters subscribe here; they cannot mutate execution records.
@MainActor
final class RunActivityCenter: ObservableObject {
    @Published private(set) var activities: [RunActivity] = []
    private var subscriptions = Set<AnyCancellable>()

    init(execution: TaskExecutionCoordinator, workflows: WorkflowRunner) {
        execution.$runs.combineLatest(workflows.$runs).sink { [weak self] tasks, flows in
            var parents: [String: String] = [:]
            for flow in flows {
                for node in flow.nodes {
                    if let childID = node.childRunID { parents[childID] = flow.id }
                }
            }
            let taskActivities = tasks.filter { $0.definition.presentation?.activityEnabled != false }
                .map { RunActivity(task: $0, parentWorkflowRunID: parents[$0.id]) }
            self?.activities = (taskActivities + flows.map { RunActivity(workflow: $0) }).sorted {
                if $0.state.isTerminal != $1.state.isTerminal { return !$0.state.isTerminal }
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.id < $1.id
            }
        }.store(in: &subscriptions)
    }
}
