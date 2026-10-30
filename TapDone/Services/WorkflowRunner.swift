import Foundation
import Combine

@MainActor
final class WorkflowRunner: ObservableObject {
    private final class Job {
        var run: WorkflowInstance
        var timer: DispatchWorkItem?
        init(_ run: WorkflowInstance) { self.run = run }
    }
    @Published private(set) var definitions: [WorkflowDefinition] = []
    @Published private(set) var runs: [WorkflowInstance] = []
    @Published private(set) var errorMessage = ""
    var canStart: () -> Bool = { true }
    private let repository = WorkflowRepository()
    private let execution: TaskExecutionCoordinator
    private var jobs: [String: Job] = [:]
    init(execution: TaskExecutionCoordinator) { self.execution = execution }

    func restore() {
        do {
            definitions = try repository.definitions()
            runs = try repository.runs()
            for index in runs.indices where !runs[index].state.terminal {
                runs[index].state = .paused
                runs[index].message = "流程已暂停。继续前会核对已有子运行，不会自动重提或重跑。"
                try repository.save(runs[index])
                jobs[runs[index].id] = Job(runs[index])
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func importDefinition(_ url: URL, library: TaskLibrary) {
        do {
            let definition = try WorkflowDefinition.decode(Data(contentsOf: url))
            _ = try definition.plan(library: library)
            try repository.save(definition)
            definitions = try repository.definitions(); errorMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }
    func start(_ definition: WorkflowDefinition, library: TaskLibrary) {
        do {
            guard canStart() else { throw TapDoneError("UPDATE_PENDING", "更新待安装，暂不启动流程。") }
            guard !runs.contains(where: { $0.plan.definition.id == definition.id && !$0.state.terminal }) else {
                throw TapDoneError("WORKFLOW_ALREADY_RUNNING", "该流程已有未结束的运行，请先处理现有运行。")
            }
            let job = Job(WorkflowInstance(plan: try definition.plan(library: library)))
            try persist(job); jobs[job.run.id] = job
            advance(job.run.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func resume(_ id: String) {
        guard let job = jobs[id], job.run.state == .paused else { return }
        do {
            guard canStart() else { throw TapDoneError("UPDATE_PENDING", "更新待安装，暂不继续流程。") }
            let snapshotLibrary = TaskLibrary(categories: [.init(id: "snapshot", name: "冻结任务", tasks: Array(job.run.plan.taskSnapshots.values))], revision: job.run.plan.libraryRevision)
            guard try job.run.plan.definition.plan(library: snapshotLibrary) == job.run.plan else {
                throw TapDoneError("INVALID_WORKFLOW_SNAPSHOT", "冻结的流程计划校验失败，不能继续。")
            }
            job.run.state = .running; job.run.message = nil
            try persist(job)
            reconcile(id)
        } catch { pause(job, error: error) }
    }
    func decide(_ id: String, nodeID: String, digest: String, approved: Bool, reason: String) -> Bool {
        guard let job = jobs[id], !job.run.state.terminal,
              let index = job.run.nodes.firstIndex(where: { $0.id == nodeID && $0.state == .waitingReview }) else { return false }
        let previous = job.run
        do {
            guard canStart() else { throw TapDoneError("UPDATE_PENDING", "更新待安装，暂不处理复核。") }
            let context = try reviewContext(job.run, nodeID: nodeID)
            let receipt = try context.decide(approved: approved, expectedDigest: digest, reviewer: NSUserName(), reason: reason)
            job.run.nodes[index].approval = receipt
            job.run.nodes[index].state = approved ? .approved : .rejected
            job.run.nodes[index].message = reason
            job.run.state = approved ? .running : .failed
            if !approved { job.run.finishedAt = Date(); job.run.message = "复核已驳回，未启动后续节点。" }
            try persist(job)
            if approved { advance(id) } else { jobs.removeValue(forKey: id) }
            return true
        } catch { job.run = previous; errorMessage = error.localizedDescription; return false }
    }
    func stop(_ id: String) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.timer?.cancel()
        job.run.state = .cancelled; job.run.finishedAt = Date()
        job.run.message = "已停止流程后续启动；远程作业可能仍在执行。"
        do { try persist(job) } catch { errorMessage = error.localizedDescription }
        for node in job.run.nodes where node.state == .running {
            if let child = node.childRunID { execution.stop(child) }
        }
    }
    func suspendAll() {
        for job in jobs.values where !job.run.state.terminal {
            job.timer?.cancel(); job.run.state = .paused; job.run.message = "应用退出，流程暂停；下次需手动继续。"
            do { try persist(job) } catch { errorMessage = error.localizedDescription }
        }
        jobs.removeAll()
    }

    private func advance(_ id: String) {
        guard let job = jobs[id], job.run.state == .running else { return }
        do {
            guard canStart() else { job.run.state = .paused; job.run.message = "更新待安装，流程暂停。"; try persist(job); return }
            guard !job.run.nodes.contains(where: { $0.state == .running || $0.state == .starting }) else { monitor(id); return }
            let ready = try job.run.plan.definition.nodes.sorted { a, b in
                job.run.plan.orderedNodeIDs.firstIndex(of: a.id)! < job.run.plan.orderedNodeIDs.firstIndex(of: b.id)!
            }.first { node in
                guard job.run.nodes.first(where: { $0.id == node.id })?.state == .pending else { return false }
                return try node.dependsOn.allSatisfy { try dependencyReady(job.run, id: $0) }
            }
            guard let node = ready else {
                guard job.run.nodes.allSatisfy({ $0.state == .succeeded || $0.state == .approved }) else {
                    throw TapDoneError("WORKFLOW_BLOCKED", "没有可执行节点，依赖未满足。")
                }
                job.run.state = .succeeded; job.run.finishedAt = Date(); job.run.message = "所有节点已完成。"
                try persist(job); jobs.removeValue(forKey: id); return
            }
            let index = job.run.nodes.firstIndex(where: { $0.id == node.id })!
            if node.kind == .review {
                job.run.nodes[index].context = try reviewContext(job.run, nodeID: node.id)
                job.run.nodes[index].state = .waitingReview; job.run.state = .waitingReview
                try persist(job); return
            }
            let outputs = Dictionary(uniqueKeysWithValues: job.run.nodes.compactMap { node -> (String, JSONValue)? in
                guard node.state == .succeeded, let output = node.output else { return nil }; return (node.id, output)
            })
            let action = try job.run.plan.action(for: node.id, outputs: outputs)
            guard !execution.isTaskActive(action.id) else { throw TapDoneError("TASK_ALREADY_RUNNING", "节点任务正在其他位置执行，请稍后继续流程。") }
            job.run.nodes[index].state = .starting
            // Persist uncertainty before starting a side effect; never replay an unbound start.
            try persist(job)
            let child = try execution.start(action) { [weak self] run in self?.receive(run, workflowID: id, nodeID: node.id) }
            job.run.nodes[index].childRunID = child.id; job.run.nodes[index].childState = child.state
            job.run.nodes[index].state = .running
            do { try persist(job) }
            catch { execution.stop(child.id); throw error }
            monitor(id)
        } catch { pause(job, error: error) }
    }
    private func receive(_ child: TaskRun, workflowID: String, nodeID: String) {
        guard let job = jobs[workflowID], job.run.state == .running,
              let index = job.run.nodes.firstIndex(where: { $0.id == nodeID && $0.childRunID == child.id && $0.state == .running }) else { return }
        do {
            job.run.nodes[index].childState = child.state
            job.run.nodes[index].message = child.summary
            if !child.state.isTerminal { try persist(job); return }
            job.timer?.cancel()
            guard try execution.history.read(child.id) == child else {
                throw TapDoneError("CHILD_RESULT_NOT_PERSISTED", "子运行最终结果尚未可靠保存，流程暂停。")
            }
            guard child.state == .succeeded, let output = child.output else {
                job.run.nodes[index].state = .failed
                job.run.state = .failed; job.run.finishedAt = Date(); job.run.message = child.summary ?? "上游没有返回有效成功结果。"
                try persist(job); jobs.removeValue(forKey: workflowID); return
            }
            let outputs = Dictionary(uniqueKeysWithValues: job.run.nodes.compactMap { node -> (String, JSONValue)? in
                guard node.state == .succeeded, let data = node.output else { return nil }; return (node.id, data)
            })
            let expected = try job.run.plan.action(for: nodeID, outputs: outputs)
            guard child.definition == expected, let contract = expected.externalProgram?.outputContract else {
                throw TapDoneError("WORKFLOW_RESULT_MISMATCH", "子运行与冻结的节点配置不匹配。")
            }
            try contract.validate(output, path: "$node.\(nodeID)")
            job.run.nodes[index].state = .succeeded; job.run.nodes[index].output = output
            try persist(job)
            advance(workflowID)
        } catch { pause(job, error: error) }
    }
    private func reconcile(_ id: String) {
        guard let job = jobs[id], job.run.state == .running else { return }
        do {
            guard !job.run.nodes.contains(where: { $0.state == .starting }) else {
                throw TapDoneError("UNCERTAIN_NODE_START", "有节点启动后未记录子运行 ID，请人工检查；不会自动重跑。")
            }
            if let node = job.run.nodes.first(where: { $0.state == .running }), let childID = node.childRunID {
                let child = try execution.history.read(childID)
                receive(child, workflowID: id, nodeID: node.id)
                if !child.state.isTerminal { monitor(id) }
            } else if job.run.nodes.contains(where: { $0.state == .waitingReview }) {
                job.run.state = .waitingReview; try persist(job)
            } else { advance(id) }
        } catch { pause(job, error: error) }
    }
    private func monitor(_ id: String) {
        guard let job = jobs[id], job.run.state == .running else { return }
        job.timer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.reconcile(id) }
        job.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timer)
    }
    private func dependencyReady(_ run: WorkflowInstance, id: String) throws -> Bool {
        guard let node = run.nodes.first(where: { $0.id == id }) else { return false }
        if node.state == .succeeded { return true }
        if node.state == .approved, let receipt = node.approval { return try receipt.authorizes(reviewContext(run, nodeID: id)) }
        return false
    }
    private func reviewContext(_ run: WorkflowInstance, nodeID: String) throws -> WorkflowReviewContext {
        guard let definition = run.plan.definition.nodes.first(where: { $0.id == nodeID && $0.kind == .review }) else {
            throw TapDoneError("INVALID_REVIEW_NODE", "复核节点不存在。")
        }
        var inputs: [String: WorkflowReviewContext.Input] = [:]
        for id in definition.dependsOn {
            guard try dependencyReady(run, id: id), let node = run.nodes.first(where: { $0.id == id }) else {
                throw TapDoneError("REVIEW_UPSTREAM_PENDING", "复核的上游尚未有效完成。")
            }
            inputs[id] = .init(runID: node.childRunID ?? run.id, output: node.output ?? .object(["approved": .bool(true)]))
        }
        return .init(workflowRunID: run.id, nodeID: nodeID, inputs: inputs)
    }
    private func persist(_ job: Job) throws {
        try repository.save(job.run)
        if let index = runs.firstIndex(where: { $0.id == job.run.id }) { runs[index] = job.run }
        else { runs.insert(job.run, at: 0) }
        errorMessage = ""
    }
    private func pause(_ job: Job, error: Error) {
        job.timer?.cancel(); job.run.state = .paused; job.run.message = error.localizedDescription
        do { try persist(job) } catch { errorMessage = "流程保存失败：\(error.localizedDescription)" }
        if errorMessage.isEmpty { errorMessage = error.localizedDescription }
    }
}
