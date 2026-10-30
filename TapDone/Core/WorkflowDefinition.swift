import Foundation
import CryptoKit

private struct WorkflowKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func workflowKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: WorkflowKey.self)
    for key in values.allKeys where try values.decodeNil(forKey: key) {
        throw TapDoneError("INVALID_WORKFLOW", "流程字段不接受 null；可选字段请省略。")
    }
    let unknown = Set(values.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        throw TapDoneError("UNKNOWN_WORKFLOW_FIELD", "未知流程字段：\(unknown.sorted().joined(separator: ", "))")
    }
}

public struct WorkflowBinding: Codable, Equatable {
    public let nodeID: String
    public let path: [String]
    private enum CodingKeys: String, CodingKey { case nodeID, path }
    public init(from decoder: Decoder) throws {
        try workflowKeys(decoder, allowed: ["nodeID", "path"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try values.decode(String.self, forKey: .nodeID)
        path = try values.decodeIfPresent([String].self, forKey: .path) ?? []
        guard path.count <= 12, path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw TapDoneError("INVALID_BINDING", "数据路径最多 12 层，属性名称不能为空或过长。")
        }
    }
}

public struct WorkflowNode: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case task, review }
    public let id: String
    public let name: String
    public let kind: Kind
    public let taskID: String?
    public let dependsOn: [String]
    public let inputBindings: [String: WorkflowBinding]
    private enum CodingKeys: String, CodingKey { case id, name, kind, taskID, dependsOn, inputBindings }
    public init(from decoder: Decoder) throws {
        try workflowKeys(decoder, allowed: ["id", "name", "kind", "taskID", "dependsOn", "inputBindings"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(Kind.self, forKey: .kind)
        taskID = try values.decodeIfPresent(String.self, forKey: .taskID)
        dependsOn = try values.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        inputBindings = try values.decodeIfPresent([String: WorkflowBinding].self, forKey: .inputBindings) ?? [:]
    }
}

public struct WorkflowDefinition: Codable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let nodes: [WorkflowNode]
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, nodes }
    public init(from decoder: Decoder) throws {
        try workflowKeys(decoder, allowed: ["schemaVersion", "id", "name", "nodes"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        nodes = try values.decode([WorkflowNode].self, forKey: .nodes)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 * 1024 else { throw TapDoneError("WORKFLOW_TOO_LARGE", "流程文件不能超过 1 MB。") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    private static func validID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }

    /// Freeze referenced definitions after a fail-closed preflight. No task is launched.
    public func plan(library: TaskLibrary) throws -> WorkflowPlan {
        guard library.isValid, schemaVersion == 1, Self.validID(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 120, (1...128).contains(nodes.count), Set(nodes.map(\.id)).count == nodes.count else {
            throw TapDoneError("INVALID_WORKFLOW", "流程版本、名称、节点数量或唯一 ID 无效。")
        }
        let ids = Set(nodes.map(\.id))
        let tasks = Dictionary(uniqueKeysWithValues: library.actions.map { ($0.id, $0) })
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var snapshots: [String: QuickAction] = [:]
        for node in nodes {
            guard Self.validID(node.id), !node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  node.name.count <= 120, node.inputBindings.count <= 128, Set(node.dependsOn).count == node.dependsOn.count,
                  Set(node.dependsOn).isSubset(of: ids), !node.dependsOn.contains(node.id) else {
                throw TapDoneError("INVALID_DEPENDENCY", "节点 \(node.id) 的名称或依赖无效。")
            }
            if node.kind == .review {
                guard node.taskID == nil, !node.dependsOn.isEmpty, node.inputBindings.isEmpty else {
                    throw TapDoneError("INVALID_REVIEW_NODE", "复核节点必须依赖上游，不能包含 taskID 或 inputBindings。")
                }
            } else {
                guard let taskID = node.taskID, let action = tasks[taskID] else {
                    throw TapDoneError("WORKFLOW_TASK_MISSING", "节点 \(node.id) 引用的任务不存在。")
                }
                // A shell exit code alone is insufficient evidence for a workflow task.
                guard action.kind == .external, let program = action.externalProgram,
                      program.protocolVersion == 2, program.inputContract != nil, program.outputContract != nil else {
                    throw TapDoneError("WORKFLOW_REQUIRES_CONTRACT", "流程任务 \(taskID) 必须是 v2 external 并声明输入输出约束。")
                }
                _ = try program.validated()
                snapshots[taskID] = action
            }
        }
        var order: [String] = []
        var resolved = Set<String>()
        while order.count < nodes.count {
            let ready = nodes.filter { !resolved.contains($0.id) && Set($0.dependsOn).isSubset(of: resolved) }
            guard !ready.isEmpty else { throw TapDoneError("WORKFLOW_CYCLE", "流程依赖包含循环，不能执行。") }
            for node in ready { order.append(node.id); resolved.insert(node.id) }
        }
        for node in nodes where !node.inputBindings.isEmpty {
            guard let taskID = node.taskID, let target = snapshots[taskID]?.externalProgram,
                  case .object = target.input else {
                throw TapDoneError("INVALID_BINDING", "带输入映射的任务 input 必须是对象。")
            }
            for (destination, binding) in node.inputBindings {
                guard !destination.isEmpty, destination.utf8.count <= 256,
                      node.dependsOn.contains(binding.nodeID), let sourceNode = byID[binding.nodeID],
                      let sourceTask = sourceNode.taskID, let source = snapshots[sourceTask]?.externalProgram,
                      let outputSchema = source.outputContract?.schema,
                      let inputSchema = target.inputContract?.schema,
                      let sourceType = Self.type(at: binding.path, in: outputSchema),
                      let targetType = Self.type(at: [destination], in: inputSchema),
                      sourceType == targetType || (sourceType == "integer" && targetType == "number") else {
                    throw TapDoneError("INVALID_BINDING", "节点 \(node.id) 的 \(destination) 映射必须引用直接依赖的已声明输出，且类型匹配。")
                }
            }
        }
        return WorkflowPlan(definition: self, libraryRevision: library.revision, orderedNodeIDs: order, taskSnapshots: snapshots)
    }

    private static func type(at path: [String], in schema: JSONValue) -> String? {
        var current = schema
        for key in path {
            guard case .object(let shape) = current, shape["type"] == .string("object"),
                  case .object(let properties)? = shape["properties"], let child = properties[key] else { return nil }
            current = child
        }
        guard case .object(let shape) = current, case .string(let type)? = shape["type"] else { return nil }
        return type
    }
}

public struct WorkflowPlan: Codable, Equatable {
    public let definition: WorkflowDefinition
    public let libraryRevision: UInt64
    public let orderedNodeIDs: [String]
    public let taskSnapshots: [String: QuickAction]

    /// The scheduler must supply only successful node outputs bound to this run.
    /// Revalidate source data, resolve explicit object paths, then validate final input.
    public func action(for nodeID: String, outputs: [String: JSONValue]) throws -> QuickAction {
        guard let node = definition.nodes.first(where: { $0.id == nodeID }), node.kind == .task,
              let taskID = node.taskID, var action = taskSnapshots[taskID], var program = action.externalProgram else {
            throw TapDoneError("WORKFLOW_TASK_MISSING", "流程快照中没有该任务节点。")
        }
        if !node.inputBindings.isEmpty {
            guard case .object(var input) = program.input else { throw TapDoneError("INVALID_BINDING", "任务输入不是对象。") }
            for (key, binding) in node.inputBindings {
                guard let sourceNode = definition.nodes.first(where: { $0.id == binding.nodeID }),
                      let sourceID = sourceNode.taskID, let contract = taskSnapshots[sourceID]?.externalProgram?.outputContract,
                      var value = outputs[binding.nodeID] else { throw TapDoneError("UPSTREAM_OUTPUT_MISSING", "上游输出尚未取得。") }
                try contract.validate(value, path: "$upstream.\(binding.nodeID)")
                for part in binding.path {
                    guard case .object(let object) = value, let child = object[part] else {
                        throw TapDoneError("BINDING_PATH_MISSING", "上游输出缺少映射属性 \(part)。")
                    }
                    value = child
                }
                input[key] = value
            }
            program.input = .object(input)
        }
        action.externalProgram = try program.validated()
        return action
    }
}

public struct WorkflowReviewContext: Codable, Equatable {
    public struct Input: Codable, Equatable {
        public let runID: String
        public let output: JSONValue
        public init(runID: String, output: JSONValue) { self.runID = runID; self.output = output }
    }
    public let workflowRunID: String
    public let nodeID: String
    public let inputs: [String: Input]
    public init(workflowRunID: String, nodeID: String, inputs: [String: Input]) {
        self.workflowRunID = workflowRunID; self.nodeID = nodeID; self.inputs = inputs
    }
    public func digest() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
    public func decide(approved: Bool, expectedDigest: String, reviewer: String, reason: String) throws -> WorkflowApproval {
        let digest = try self.digest()
        guard digest == expectedDigest, !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 4096 else {
            throw TapDoneError("REVIEW_CONTEXT_CHANGED", "复核内容已变化，或缺少复核人和理由。")
        }
        return WorkflowApproval(workflowRunID: workflowRunID, nodeID: nodeID, contextDigest: digest,
                                approved: approved, reviewer: reviewer, reason: reason, decidedAt: Date())
    }
}

public struct WorkflowApproval: Codable, Equatable {
    public let workflowRunID: String
    public let nodeID: String
    public let contextDigest: String
    public let approved: Bool
    public let reviewer: String
    public let reason: String
    public let decidedAt: Date
    public func authorizes(_ context: WorkflowReviewContext) throws -> Bool {
        guard approved, workflowRunID == context.workflowRunID, nodeID == context.nodeID else { return false }
        return contextDigest == (try context.digest())
    }
}
