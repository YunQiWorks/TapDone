import Foundation
import Darwin

/// An execution instance is separate from its editable task definition.
public struct TaskRun: Identifiable, Codable, Equatable {
    public enum State: String, Codable {
        case running, waitingExternal, succeeded, failed, cancelled, timedOut, interrupted
        public var title: String {
            switch self {
            case .running: return "运行中"
            case .waitingExternal: return "等待远程结果"
            case .succeeded: return "成功"
            case .failed: return "失败"
            case .cancelled: return "已停止"
            case .timedOut: return "已超时"
            case .interrupted: return "已中断"
            }
        }
        public var isTerminal: Bool { self != .running && self != .waitingExternal }
    }
    public struct Event: Codable, Equatable {
        public let sequence: Int
        public let state: State
        public let timestamp: Date
        public let message: String?
    }
    public let formatVersion: Int
    public let id: String
    public let taskID: String
    public let title: String
    public let logURL: URL
    public let startedAt: Date
    public let definition: QuickAction
    public private(set) var remoteJob: RemoteJobCheckpoint?
    public var resultURL: URL?
    public private(set) var summary: String?
    public private(set) var finishedAt: Date?
    public private(set) var exitCode: Int32?
    public private(set) var output: JSONValue?
    public private(set) var state: State = .running
    public private(set) var events: [Event]

    public init(id: String, definition: QuickAction, logURL: URL, startedAt: Date = Date()) {
        self.formatVersion = 1
        self.id = id; self.taskID = definition.id; self.title = definition.title
        self.definition = definition; self.logURL = logURL; self.startedAt = startedAt
        events = [Event(sequence: 1, state: .running, timestamp: startedAt, message: nil)]
    }

    public var canStop: Bool { !state.isTerminal && (definition.kind == .command || definition.kind == .external) }

    public mutating func waitForRemote(_ checkpoint: RemoteJobCheckpoint, message: String?) throws {
        guard !state.isTerminal, definition.externalProgram?.asyncOptions != nil,
              remoteJob == nil || remoteJob?.jobID == checkpoint.jobID else {
            throw TapDoneError("INVALID_RUN_TRANSITION", "远程作业身份变化或运行已经结束。")
        }
        remoteJob = checkpoint; state = .waitingExternal; summary = message
        events.append(Event(sequence: events.count + 1, state: state, timestamp: Date(), message: message))
    }

    /// Terminal states cannot be overwritten by duplicate/late completions.
    public mutating func complete(state: State, exitCode: Int32?, summary: String?, output: JSONValue? = nil) throws {
        guard !self.state.isTerminal, state.isTerminal else {
            throw TapDoneError("INVALID_RUN_TRANSITION", "已结束的运行不能再次完成。")
        }
        let now = Date()
        self.state = state; self.exitCode = exitCode; self.summary = summary
        self.output = output; self.finishedAt = now
        events.append(Event(sequence: events.count + 1, state: state, timestamp: now, message: summary))
    }
}

/// Strict v2 terminal envelope. v1 remains available to existing scripts.
public struct TaskResultEnvelope: Decodable {
    public let protocolVersion: Int
    public let taskID: String
    public let runID: String
    public let ok: Bool
    public let message: String?
    public let data: JSONValue?

    private enum CodingKeys: String, CodingKey { case protocolVersion, taskID, runID, ok, message, data }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        taskID = try values.decode(String.self, forKey: .taskID)
        runID = try values.decode(String.self, forKey: .runID)
        ok = try values.decode(Bool.self, forKey: .ok)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        data = values.contains(.data) ? try values.decode(JSONValue.self, forKey: .data) : nil
    }

    public static func decode(_ data: Data, taskID: String, runID: String) throws -> TaskResultEnvelope {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["protocolVersion", "taskID", "runID", "ok", "message", "data"]) else {
            throw TapDoneError("INVALID_RESULT", "返回结果包含未知字段或不是 JSON 对象。")
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.protocolVersion == 2, result.taskID == taskID, result.runID == runID else {
            throw TapDoneError("RESULT_IDENTITY_MISMATCH", "返回结果的协议版本、任务或运行 ID 不匹配。")
        }
        return result
    }
}

/// One atomic snapshot per run, including its ordered lifecycle events.
/// The application owns execution; the CLI can read records in later versions.
public final class TaskRunRepository {
    public let directoryURL: URL
    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? TaskRepository().directoryURL.appendingPathComponent("Runs", isDirectory: true)
    }
    public func save(_ run: TaskRun) throws {
        guard UUID(uuidString: run.id) != nil else { throw TapDoneError("INVALID_RUN_ID", "运行 ID 不合法。") }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let url = directoryURL.appendingPathComponent(run.id + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let temporary = directoryURL.appendingPathComponent("." + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try encoder.encode(run)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw TapDoneError("RUN_STORAGE_FAILED", "无法创建运行记录。")
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw TapDoneError("RUN_STORAGE_FAILED", "无法原子保存运行记录。")
        }
    }
    public func read(_ id: String) throws -> TaskRun {
        guard UUID(uuidString: id) != nil else { throw TapDoneError("INVALID_RUN_ID", "运行 ID 不合法。") }
        let run = try JSONDecoder().decode(TaskRun.self, from: Data(contentsOf: directoryURL.appendingPathComponent(id + ".json")))
        guard run.formatVersion == 1, run.id == id, run.taskID == run.definition.id else {
            throw TapDoneError("INVALID_RUN_RECORD", "运行记录格式或身份无效。")
        }
        return run
    }
    public func load() throws -> [TaskRun] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let run = try JSONDecoder().decode(TaskRun.self, from: Data(contentsOf: url))
                guard run.formatVersion == 1, UUID(uuidString: run.id) != nil,
                      url.deletingPathExtension().lastPathComponent == run.id,
                      run.taskID == run.definition.id else {
                    throw TapDoneError("INVALID_RUN_RECORD", "运行记录格式不受支持或身份不匹配。")
                }
                return run
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
    public func recover() throws -> [TaskRun] {
        var runs = try load()
        for index in runs.indices where !runs[index].state.isTerminal {
            if runs[index].state == .waitingExternal, runs[index].remoteJob != nil,
               runs[index].definition.externalProgram?.asyncOptions != nil { continue }
            try runs[index].complete(state: .interrupted, exitCode: nil,
                                     summary: "上次运行未记录最终结果，状态无法确认。请检查日志及外部产物；不会自动重试。")
            try save(runs[index])
        }
        return runs
    }
}

/// Versioned, data-only view of execution. No executable input or business output is exposed.
public struct RunActivity: Identifiable, Equatable, Encodable {
    public enum Source: String, Encodable { case task, workflow }
    public enum State: String, Encodable {
        case running, waitingExternal, waitingReview, paused, succeeded, failed, cancelled, timedOut, interrupted
        public var title: String {
            switch self {
            case .running: return "运行中"
            case .waitingExternal: return "等待远程结果"
            case .waitingReview: return "等待复核"
            case .paused: return "已暂停"
            case .succeeded: return "成功"
            case .failed: return "失败"
            case .cancelled: return "已停止"
            case .timedOut: return "已超时"
            case .interrupted: return "已中断"
            }
        }
        public var isTerminal: Bool {
            switch self { case .running, .waitingExternal, .waitingReview, .paused: return false; default: return true }
        }
    }
    public enum Capability: String, Encodable { case stop, stopTracking, resume, review, openLog }
    public struct NodeProgress: Equatable, Encodable {
        public let completed: Int
        public let total: Int
        public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }
    public let schemaVersion = 1
    public let source: Source
    public let runID: String
    public var id: String { source.rawValue + ":" + runID }
    public let definitionID: String
    public let title: String
    public let state: State
    public let startedAt: Date
    public let finishedAt: Date?
    public let symbol: String
    public let builtinIconID: String?
    public let iconAssetID: String?
    public let progress: NodeProgress?
    public let capabilities: [Capability]
    public let parentWorkflowRunID: String?

    public init(task: TaskRun, parentWorkflowRunID: String? = nil) {
        source = .task; runID = task.id; definitionID = task.taskID
        title = task.definition.presentation?.activityTitle ?? task.title
        state = State(rawValue: task.state.rawValue) ?? .interrupted
        startedAt = task.startedAt; finishedAt = task.finishedAt
        builtinIconID = task.definition.presentation?.builtinIconID
        symbol = task.definition.symbol; iconAssetID = task.definition.presentation?.iconAssetID
        progress = nil // No invented percentage for an opaque external operation.
        if task.canStop {
            capabilities = [.openLog, task.definition.externalProgram?.asyncOptions != nil ? .stopTracking : .stop]
        } else { capabilities = [.openLog] }
        self.parentWorkflowRunID = parentWorkflowRunID
    }

    public init(workflow: WorkflowInstance) {
        source = .workflow; runID = workflow.id; definitionID = workflow.plan.definition.id
        title = workflow.plan.definition.name
        state = State(rawValue: workflow.state.rawValue) ?? .interrupted
        startedAt = workflow.startedAt; finishedAt = workflow.finishedAt
        builtinIconID = nil
        symbol = "point.3.connected.trianglepath.dotted"; iconAssetID = nil
        progress = NodeProgress(completed: workflow.nodes.filter { $0.state == .succeeded || $0.state == .approved }.count,
                                total: workflow.nodes.count)
        switch workflow.state {
        case .paused: capabilities = [.resume, .stop]
        case .waitingReview: capabilities = [.review, .stop]
        case .running: capabilities = [.stop]
        default: capabilities = []
        }
        parentWorkflowRunID = nil
    }
}
