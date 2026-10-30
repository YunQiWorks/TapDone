import Foundation
import Darwin
import CryptoKit

public struct WorkflowInstance: Identifiable, Codable {
    public enum State: String, Codable {
        case running, paused, waitingReview, succeeded, failed, cancelled
        public var terminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
        public var title: String {
            switch self {
            case .running: return "执行中"
            case .paused: return "已暂停"
            case .waitingReview: return "等待复核"
            case .succeeded: return "成功"
            case .failed: return "失败"
            case .cancelled: return "已停止"
            }
        }
    }
    public struct Node: Identifiable, Codable {
        public enum State: String, Codable {
            case pending, starting, running, waitingReview, succeeded, approved, rejected, failed
            public var title: String {
                switch self {
                case .pending: return "待执行"
                case .starting: return "启动确认中"
                case .running: return "执行中"
                case .waitingReview: return "待复核"
                case .succeeded: return "成功"
                case .approved: return "已批准"
                case .rejected: return "已驳回"
                case .failed: return "失败"
                }
            }
        }
        public let id: String
        public var state: State = .pending
        public var childRunID: String?
        public var childState: TaskRun.State?
        public var output: JSONValue?
        public var context: WorkflowReviewContext?
        public var approval: WorkflowApproval?
        public var message: String?
        public init(id: String) { self.id = id }
    }
    public let formatVersion: Int
    public let id: String
    public let plan: WorkflowPlan
    public let startedAt: Date
    public var state: State = .running
    public var nodes: [Node]
    public var message: String?
    public var finishedAt: Date?
    public init(plan: WorkflowPlan) {
        formatVersion = 1; id = UUID().uuidString; self.plan = plan; startedAt = Date()
        nodes = plan.orderedNodeIDs.map { Node(id: $0) }
    }
}

/// App-owned workflow definitions and immutable-plan execution snapshots.
public final class WorkflowRepository {
    public let directoryURL: URL
    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? TaskRepository().directoryURL.appendingPathComponent("Workflows", isDirectory: true)
    }
    private func write<T: Encodable>(_ value: T, folder: String, key: String) throws {
        let directory = directoryURL.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent(name + ".json")
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(value), attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, destination.path) == 0 else { throw TapDoneError("WORKFLOW_STORAGE_FAILED", "无法保存流程记录。") }
    }
    private func read<T: Decodable>(_ type: T.Type, folder: String) throws -> [T] {
        let directory = directoryURL.appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(type, from: Data(contentsOf: $0)) }
    }
    public func save(_ definition: WorkflowDefinition) throws { try write(definition, folder: "Definitions", key: definition.id) }
    public func save(_ run: WorkflowInstance) throws { try write(run, folder: "Runs", key: run.id) }
    public func definitions() throws -> [WorkflowDefinition] { try read(WorkflowDefinition.self, folder: "Definitions").sorted { $0.name < $1.name } }
    public func runs() throws -> [WorkflowInstance] {
        let runs = try read(WorkflowInstance.self, folder: "Runs")
        guard Set(runs.map(\.id)).count == runs.count, runs.allSatisfy({ $0.formatVersion == 1 && UUID(uuidString: $0.id) != nil
            && $0.nodes.map(\.id) == $0.plan.orderedNodeIDs
            && Set($0.nodes.map(\.id)).count == $0.nodes.count
            && $0.nodes.count == $0.plan.definition.nodes.count }) else { throw TapDoneError("INVALID_WORKFLOW_RUN", "流程运行记录格式无效。") }
        return runs.sorted { $0.startedAt > $1.startedAt }
    }
}
