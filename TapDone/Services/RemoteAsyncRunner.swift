import Foundation

/// Durable parent runs wrap short-lived, identity-checked v2 adapter invocations.
@MainActor
final class RemoteAsyncRunner {
    private final class Job {
        var run: TaskRun
        let deadline: Date
        let update: (TaskRun) -> Void
        var timer: DispatchWorkItem?
        var stepID: String?
        init(run: TaskRun, deadline: Date, update: @escaping (TaskRun) -> Void) {
            self.run = run; self.deadline = deadline; self.update = update
        }
    }
    let history: TaskRunRepository
    private let steps: CommandRunner
    private var jobs: [String: Job] = [:]
    private var storageError: String?
    var persistenceError: String? { storageError ?? steps.persistenceError }

    init(history: TaskRunRepository) {
        self.history = history
        steps = CommandRunner(history: TaskRunRepository(directoryURL: history.directoryURL.appendingPathComponent("Steps", isDirectory: true)))
    }

    func start(_ action: QuickAction, update: @escaping (TaskRun) -> Void) throws -> TaskRun {
        guard let program = action.externalProgram, let options = program.asyncOptions else {
            throw TapDoneError("INVALID_ASYNC_OPTIONS", "缺少异步任务配置。")
        }
        _ = try program.validated()
        let id = UUID().uuidString
        let logs = history.directoryURL.deletingLastPathComponent().appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = logs.appendingPathComponent(id + ".log")
        guard FileManager.default.createFile(atPath: url.path, contents: Data("TapDone · 远程异步任务\n".utf8), attributes: [.posixPermissions: 0o600]) else {
            throw TapDoneError("RUN_STORAGE_FAILED", "无法创建异步任务日志。")
        }
        let run = TaskRun(id: id, definition: action, logURL: url)
        try history.save(run)
        jobs[id] = Job(run: run, deadline: run.startedAt.addingTimeInterval(options.timeoutSeconds), update: update)
        // Return the initial record before publishing any subsequent state.
        DispatchQueue.main.async { [weak self] in self?.invoke(id, submitting: true) }
        return run
    }

    func resume(_ run: TaskRun, update: @escaping (TaskRun) -> Void) throws {
        guard run.state == .waitingExternal, let checkpoint = run.remoteJob,
              let program = run.definition.externalProgram else { return }
        _ = try program.validated()
        guard !checkpoint.jobID.isEmpty, checkpoint.jobID.utf8.count <= 256,
              checkpoint.deadline.timeIntervalSince1970.isFinite,
              checkpoint.nextPollAt.timeIntervalSince1970.isFinite,
              let options = program.asyncOptions,
              abs(checkpoint.deadline.timeIntervalSince(run.startedAt) - options.timeoutSeconds) < 1 else {
            throw TapDoneError("INVALID_REMOTE_CHECKPOINT", "远程作业恢复记录无效。")
        }
        let job = Job(run: run, deadline: checkpoint.deadline, update: update)
        jobs[run.id] = job
        schedule(run.id, at: checkpoint.nextPollAt)
    }

    func contains(_ id: String) -> Bool { jobs[id] != nil }

    func stop(_ id: String) {
        finish(id, state: .interrupted, message: "已停止跟踪；远程作业可能仍在执行，未请求远程取消。")
    }

    func suspendAll() {
        // Persisted waiting jobs resume polling next launch. Never resubmit an uncertain submission.
        for id in Array(jobs.keys) {
            guard let job = jobs.removeValue(forKey: id) else { continue }
            job.timer?.cancel()
            if job.run.remoteJob == nil {
                var run = job.run
                try? run.complete(state: .interrupted, exitCode: nil, summary: "退出时尚未确认作业 ID；请人工检查，不会自动重新提交。")
                save(run); job.update(run)
            }
        }
        steps.stopAll()
    }

    private func schedule(_ id: String, at date: Date) {
        guard let job = jobs[id] else { return }
        job.timer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.invoke(id, submitting: false) }
        job.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, min(date, job.deadline).timeIntervalSinceNow), execute: timer)
    }

    private func invoke(_ id: String, submitting: Bool) {
        guard let job = jobs[id], let source = job.run.definition.externalProgram else { return }
        guard Date() < job.deadline else {
            finish(id, state: .timedOut, message: "等待远程结果超时；远程作业未被取消。")
            return
        }
        var action = job.run.definition
        var program = source
        program.asyncOptions = nil; program.inputContract = nil; program.outputContract = nil
        var context: [String: JSONValue] = ["operation": .string(submitting ? "submit" : "poll"),
            "parentRunID": .string(id), "payload": source.input]
        if let checkpoint = job.run.remoteJob { context["jobID"] = .string(checkpoint.jobID) }
        program.input = .object(context)
        program.options.timeoutSeconds = max(1, min(program.options.timeoutSeconds, job.deadline.timeIntervalSinceNow))
        action.externalProgram = program
        do {
            let step = try steps.start(action) { [weak self] result in self?.receive(result, parentID: id, submitting: submitting) }
            job.stepID = step.id
            append("\(submitting ? "提交" : "查询") · \(step.id) · 日志：\(step.logURL.path)", to: job.run.logURL)
            // Also bound a currently running adapter invocation by the overall deadline.
            let timer = DispatchWorkItem { [weak self] in
                self?.finish(id, state: .timedOut, message: "等待远程结果超时；远程作业未被取消。")
            }
            job.timer?.cancel(); job.timer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, job.deadline.timeIntervalSinceNow), execute: timer)
        } catch {
            finish(id, state: .interrupted, message: "无法\(submitting ? "提交" : "查询")远程任务：\(error.localizedDescription)；不会自动重新提交。")
        }
    }

    private func receive(_ step: TaskRun, parentID: String, submitting: Bool) {
        guard let job = jobs[parentID], job.stepID == step.id else { return }
        job.stepID = nil; job.timer?.cancel()
        guard Date() < job.deadline else {
            finish(parentID, state: .timedOut, message: "收到结果时已超过截止时间；远程作业未被取消。")
            return
        }
        guard step.state == .succeeded else {
            finish(parentID, state: .interrupted, message: "远程\(submitting ? "提交" : "查询")未返回有效结果：\(step.summary ?? step.state.title)。不会自动重新提交。")
            return
        }
        do {
            let response = try RemoteJobResponse.decode(step.output, expectedJobID: job.run.remoteJob?.jobID)
            if job.run.remoteJob == nil {
                try job.run.waitForRemote(RemoteJobCheckpoint(jobID: response.jobID, deadline: job.deadline, nextPollAt: Date()), message: response.message)
            }
            switch response.status {
            case .submitted, .running:
                guard let options = job.run.definition.externalProgram?.asyncOptions else { return }
                let next = Date().addingTimeInterval(options.pollIntervalSeconds)
                try job.run.waitForRemote(RemoteJobCheckpoint(jobID: response.jobID, deadline: job.deadline, nextPollAt: next),
                    message: response.message ?? "远程作业已提交，等待最终结果。")
                // Do not continue querying unless the confirmed job ID is durably saved.
                try history.save(job.run)
                storageError = nil
                job.update(job.run)
                schedule(parentID, at: next)
            case .succeeded:
                if let contract = job.run.definition.externalProgram?.outputContract {
                    guard let output = response.result else { throw TapDoneError("REMOTE_OUTPUT_MISSING", "缺少远程产物。") }
                    try contract.validate(output, path: "$output")
                }
                finish(parentID, state: .succeeded, message: response.message ?? "远程任务已完成。", output: response.result)
            case .failed:
                finish(parentID, state: .failed, message: response.message ?? "远程任务返回失败。")
            }
        } catch {
            finish(parentID, state: .interrupted, message: "远程结果无法确认：\(error.localizedDescription)")
        }
    }

    private func finish(_ id: String, state: TaskRun.State, message: String, output: JSONValue? = nil) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.timer?.cancel()
        if let step = job.stepID { steps.stop(step) }
        do { try job.run.complete(state: state, exitCode: nil, summary: message, output: output) }
        catch { storageError = error.localizedDescription }
        save(job.run)
        append(message, to: job.run.logURL)
        job.update(job.run)
    }
    private func save(_ run: TaskRun) {
        do { try history.save(run); storageError = nil }
        catch { storageError = "远程运行记录保存失败：\(error.localizedDescription)" }
    }
    private func append(_ message: String, to url: URL) {
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd(); try? file.write(contentsOf: Data((message + "\n").utf8))
        }
    }
}
