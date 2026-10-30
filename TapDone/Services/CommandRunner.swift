import Foundation
import Darwin

typealias CommandRun = TaskRun

@MainActor
final class CommandRunner {
    private final class Job {
        let pid: pid_t
        var run: CommandRun
        var stopReason: CommandRun.State?
        var timeout: DispatchWorkItem?
        let inputURL: URL?
        let completion: (CommandRun) -> Void
        init(pid: pid_t, run: CommandRun, inputURL: URL?, completion: @escaping (CommandRun) -> Void) {
            self.pid = pid; self.run = run; self.inputURL = inputURL; self.completion = completion
        }
    }
    private var jobs: [String: Job] = [:]
    let history: TaskRunRepository
    init(history: TaskRunRepository = TaskRunRepository()) { self.history = history }
    private(set) var persistenceError: String?

    func start(_ action: QuickAction, completion: @escaping (CommandRun) -> Void) throws -> CommandRun {
        let program: ExternalProgram?
        let options: CommandOptions
        let executable: String
        let argumentStrings: [String]
        if action.kind == .external, let configuration = action.externalProgram {
            let external = try configuration.validated()
            program = external; options = external.options
            executable = external.executable; argumentStrings = [executable] + external.arguments
        } else if action.kind == .command, let configuration = action.commandOptions {
            program = nil; options = try configuration.validated(command: action.target)
            executable = "/bin/zsh"; argumentStrings = [executable, "-lc", action.target]
        } else { throw TapDoneError("INVALID_COMMAND", "缺少命令或外部扩展配置。") }
        let runID = UUID().uuidString
        let logs = TaskRepository().directoryURL.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent(runID + ".log")
        let header = "TapDone · \(action.title)\n开始时间：\(ISO8601DateFormatter().string(from: Date()))\n工作目录：\(options.workingDirectory)\n\n"
        try Data(header.utf8).write(to: logURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        var run = CommandRun(id: runID, definition: action, logURL: logURL)
        var inputURL: URL?
        var launched = false
        defer {
            if !launched, let inputURL { try? FileManager.default.removeItem(at: inputURL) }
        }
        if let program {
            let requestURL = logs.appendingPathComponent(runID + ".input.json")
            let request = ExternalRequest(taskID: action.id, runID: runID, input: program.input, protocolVersion: program.protocolVersion ?? 1)
            try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
            inputURL = requestURL
            let resultURL = logs.appendingPathComponent(runID + ".result.json")
            try Data().write(to: resultURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resultURL.path)
            run.resultURL = resultURL
        }

        // Fail before launching any side effects if the initial record cannot be saved.
        try history.save(run)
        defer {
            if !launched {
                try? run.complete(state: .failed, exitCode: nil, summary: "进程启动失败，任务未执行。")
                persist(run)
            }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addchdir_np(&actions, options.workingDirectory))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, inputURL?.path ?? "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, run.resultURL?.path ?? logURL.path, O_WRONLY | O_APPEND, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, logURL.path, O_WRONLY | O_APPEND, 0))
        // Each task owns a process group, so stop/timeout also reaches child processes.
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGPIPE)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, flags))
        var environment = ProcessInfo.processInfo.environment
        environment.merge(options.environment, uniquingKeysWith: { _, configured in configured })
        if program != nil {
            environment["TAPDONE_PROTOCOL_VERSION"] = String(program?.protocolVersion ?? 1)
            environment["TAPDONE_TASK_ID"] = action.id
            environment["TAPDONE_RUN_ID"] = runID
            // Legacy names remain available to existing extension scripts.
            environment["SIDETAP_PROTOCOL_VERSION"] = environment["TAPDONE_PROTOCOL_VERSION"]
            environment["SIDETAP_TASK_ID"] = action.id
            environment["SIDETAP_RUN_ID"] = runID
        }
        var argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { $0.withCString { strdup($0) } } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.sorted(by: { $0.key < $1.key }).map { ($0.key + "=" + $0.value).withCString { strdup($0) } } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let launchCode = argv.withUnsafeMutableBufferPointer { arguments in
            envp.withUnsafeMutableBufferPointer { variables in
                posix_spawn(&pid, executable, &actions, &attributes, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        try check(launchCode)
        launched = true
        let job = Job(pid: pid, run: run, inputURL: inputURL, completion: completion)
        jobs[runID] = job
        let timeout = DispatchWorkItem { [weak self] in self?.stop(runID, reason: .timedOut) }
        job.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeoutSeconds, execute: timeout)
        let childPID = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(childPID, &status, 0) } while result < 0 && errno == EINTR
            let finalStatus = status
            let waitFailed = result < 0
            DispatchQueue.main.async { [weak self] in
                self?.finish(runID, status: finalStatus, waitFailed: waitFailed)
            }
        }
        return run
    }

    func stop(_ runID: String, reason: CommandRun.State = .cancelled) {
        guard let job = jobs[runID], job.stopReason == nil else { return }
        job.stopReason = reason
        kill(-job.pid, SIGTERM)
        let group = job.pid
        // Escalate even if the shell exits first but a child ignores SIGTERM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        }
    }

    func stopAll() {
        for id in Array(jobs.keys) {
            stop(id)
            if let job = jobs[id] {
                kill(-job.pid, SIGKILL)
                if let inputURL = job.inputURL { try? FileManager.default.removeItem(at: inputURL) }
                job.timeout?.cancel()
                // Record the stop request without inventing an unobserved exit code.
                try? job.run.complete(state: .cancelled, exitCode: nil, summary: "应用退出，已请求终止运行及子进程。")
                persist(job.run)
                jobs.removeValue(forKey: id)
                job.completion(job.run)
            }
        }
    }

    private func finish(_ runID: String, status: Int32, waitFailed: Bool) {
        guard let job = jobs.removeValue(forKey: runID) else { return }
        job.timeout?.cancel()
        if let inputURL = job.inputURL { try? FileManager.default.removeItem(at: inputURL) }
        let signal = status & 0x7f
        let code: Int32 = waitFailed ? -1 : signal == 0 ? (status >> 8) & 0xff : 128 + signal
        var finalState = job.stopReason ?? (code == 0 ? CommandRun.State.succeeded : .failed)
        var message: String?
        var output: JSONValue?
        if let resultURL = job.run.resultURL, job.stopReason == nil {
            do {
                let handle = try FileHandle(forReadingFrom: resultURL)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
                guard data.count <= 1024 * 1024 else { throw TapDoneError("RESULT_TOO_LARGE", "扩展结果超过 1 MB。") }
                if job.run.definition.externalProgram?.protocolVersion == 2 {
                    let response = try TaskResultEnvelope.decode(data, taskID: job.run.taskID, runID: runID)
                    message = response.message; output = response.data
                    if !response.ok { finalState = .failed }
                } else {
                    let response = try JSONDecoder().decode(ExternalResponse.self, from: data)
                    guard response.protocolVersion == 1 else { throw TapDoneError("INVALID_RESULT", "扩展返回的 protocolVersion 不受支持。") }
                    message = response.message; output = response.data
                    if !response.ok { finalState = .failed }
                }
            } catch {
                finalState = .failed
                message = "扩展未返回有效的协议结果：\(error.localizedDescription)"
            }
        }
        if finalState == .succeeded, let contract = job.run.definition.externalProgram?.outputContract {
            do {
                guard let output else { throw TapDoneError("OUTPUT_MISSING", "声明输出约束的任务必须返回 data 字段。") }
                try contract.validate(output, path: "$output")
            }
            catch {
                finalState = .failed
                message = "返回数据不满足任务约束：\(error.localizedDescription)"
                // Keep raw stdout on disk, but never expose invalid data as validated output.
                output = nil
            }
        }
        // A nonzero exit status never becomes success merely because JSON says ok.
        do { try job.run.complete(state: finalState, exitCode: code, summary: message, output: output) }
        catch { persistenceError = error.localizedDescription }
        persist(job.run)
        let summary = job.run.summary.map { "\n" + $0 } ?? ""
        let footer = "\n\nTapDone · \(job.run.state.title) · exit \(code)\(summary)\n"
        if let handle = try? FileHandle(forWritingTo: job.run.logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(footer.utf8))
        }
        job.completion(job.run)
    }

    private func persist(_ run: CommandRun) {
        do { try history.save(run); persistenceError = nil }
        catch { persistenceError = "运行记录保存失败：\(error.localizedDescription)" }
    }

    private func check(_ code: Int32) throws {
        guard code == 0 else { throw TapDoneError("COMMAND_START_FAILED", "无法启动命令：\(String(cString: strerror(code)))") }
    }
}
