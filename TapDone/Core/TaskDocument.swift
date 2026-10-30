import Foundation

public struct TapDoneError: LocalizedError {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// Public interchange format, deliberately distinct from the internal library file.
public struct TaskDocument: Codable {
    public var schemaVersion: Int
    public var id: String
    public var category: String
    public var name: String
    public var icon: String?
    public var presentation: TaskPresentation?
    public var showInDock: Bool?
    public var action: DocumentAction

    public struct DocumentAction: Codable {
        public var inputContract: PayloadContract?
        public var outputContract: PayloadContract?
        public var asyncOptions: RemoteAsyncOptions?
        public var protocolVersion: Int?
        public var type: String
        public var path: String?
        public var url: String?
        public var bundleIdentifier: String?
        public var command: String?
        public var workingDirectory: String?
        public var timeoutSeconds: Double?
        public var environment: [String: String]?
        public var executable: String?
        public var arguments: [String]?
        public var input: JSONValue?

        private enum CodingKeys: String, CodingKey { case asyncOptions, inputContract, outputContract, protocolVersion, type, path, url, bundleIdentifier, command, workingDirectory, timeoutSeconds, environment, executable, arguments, input }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            asyncOptions = try values.decodeIfPresent(RemoteAsyncOptions.self, forKey: .asyncOptions)
            inputContract = try values.decodeIfPresent(PayloadContract.self, forKey: .inputContract)
            outputContract = try values.decodeIfPresent(PayloadContract.self, forKey: .outputContract)
            protocolVersion = try values.decodeIfPresent(Int.self, forKey: .protocolVersion)
            type = try values.decode(String.self, forKey: .type)
            path = try values.decodeIfPresent(String.self, forKey: .path)
            url = try values.decodeIfPresent(String.self, forKey: .url)
            bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            command = try values.decodeIfPresent(String.self, forKey: .command)
            workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
            timeoutSeconds = try values.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            environment = try values.decodeIfPresent([String: String].self, forKey: .environment)
            executable = try values.decodeIfPresent(String.self, forKey: .executable)
            arguments = try values.decodeIfPresent([String].self, forKey: .arguments)
            input = values.contains(.input) ? try values.decode(JSONValue.self, forKey: .input) : nil
        }
    }

    public static func decode(_ data: Data) throws -> [TaskDocument] {
        do {
            let decoder = JSONDecoder()
            // Accept exactly one task, or an array for an all-or-nothing batch.
            let value = try JSONSerialization.jsonObject(with: data)
            let rawTasks = (value as? [Any]) ?? [value]
            for raw in rawTasks {
                guard let object = raw as? [String: Any], let action = object["action"] as? [String: Any] else {
                    throw TapDoneError("INVALID_JSON", "每个任务必须是包含 action 对象的 JSON 对象。")
                }
                let allowed = Set(["schemaVersion", "id", "category", "name", "presentation", "icon", "showInDock", "action"])
                let unknown = Set(object.keys).subtracting(allowed)
                let allowedAction: Set<String>
                switch action["type"] as? String {
                case "application": allowedAction = ["type", "bundleIdentifier"]
                case "website": allowedAction = ["type", "url"]
                case "external": allowedAction = ["asyncOptions","inputContract", "outputContract", "protocolVersion", "type", "executable", "arguments", "input", "workingDirectory", "timeoutSeconds", "environment"]
                case "command": allowedAction = ["type", "command", "workingDirectory", "timeoutSeconds", "environment"]
                case "open", "folder", "file": allowedAction = ["type", "path"]
                default: allowedAction = ["type", "path", "url", "bundleIdentifier"]
                }
                let unknownAction = Set(action.keys).subtracting(allowedAction)
                guard !object.values.contains(where: { $0 is NSNull }), !action.contains(where: { $0.key != "input" && $0.value is NSNull }) else {
                    throw TapDoneError("INVALID_JSON", "任务字段不接受 null；可选字段请直接省略。")
                }
                guard unknown.isEmpty, unknownAction.isEmpty else {
                    throw TapDoneError("UNKNOWN_FIELD", "未知字段：\((unknown.union(unknownAction)).sorted().joined(separator: ", "))")
                }
            }
            let documents: [TaskDocument]
            if value is [Any] { documents = try decoder.decode([TaskDocument].self, from: data) }
            else { documents = [try decoder.decode(TaskDocument.self, from: data)] }
            guard !documents.isEmpty else { throw TapDoneError("EMPTY_BATCH", "任务列表不能为空。") }
            guard Set(documents.map(\.id)).count == documents.count else {
                throw TapDoneError("DUPLICATE_ID", "同一批任务包含重复 ID。")
            }
            return documents
        } catch let error as TapDoneError { throw error }
        catch { throw TapDoneError("INVALID_JSON", "任务 JSON 格式不正确：\(error.localizedDescription)") }
    }

    public func validatedAction() throws -> QuickAction {
        guard schemaVersion == 1 else { throw TapDoneError("UNSUPPORTED_VERSION", "仅支持 schemaVersion 1。") }
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw TapDoneError("INVALID_ID", "任务 ID 必须为 1–128 位字母、数字、点、下划线或连字符，且以字母或数字开头。")
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, !group.isEmpty, group.count <= 80 else {
            throw TapDoneError("INVALID_NAME", "任务名称需为 1–120 字，分类名称需为 1–80 字。")
        }
        let kind: ActionKind
        let target: String
        var options: CommandOptions?
        var external: ExternalProgram?
        switch action.type {
        case "application":
            guard action.path == nil, action.url == nil,
                  let identifier = action.bundleIdentifier,
                  identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
                throw TapDoneError("INVALID_APPLICATION", "application 需提供 bundleIdentifier，不可同时提供 path 或 url。")
            }
            kind = .application; target = identifier
        case "website":
            guard action.path == nil, action.bundleIdentifier == nil,
                  let value = action.url, let url = URL(string: value),
                  let scheme = url.scheme, ["https", "http"].contains(scheme.lowercased()),
                  let host = url.host, !host.isEmpty else {
                throw TapDoneError("INVALID_URL", "website 需提供有效的 HTTP/HTTPS url。")
            }
            kind = .website; target = url.absoluteString
        case "external":
            guard let executable = action.executable, let directory = action.workingDirectory else {
                throw TapDoneError("INVALID_EXTERNAL", "external 需要 executable 和 workingDirectory。")
            }
            let program = try ExternalProgram(executable: executable, arguments: action.arguments ?? [], input: action.input ?? .object([:]),
                options: CommandOptions(workingDirectory: directory, timeoutSeconds: action.timeoutSeconds ?? 300,
                                        environment: action.environment ?? [:]), protocolVersion: action.protocolVersion ?? 1, inputContract: action.inputContract, outputContract: action.outputContract, asyncOptions: action.asyncOptions).validated()
            external = program
            kind = .external; target = program.executable
        case "command":
            guard let command = action.command, let directory = action.workingDirectory else {
                throw TapDoneError("INVALID_COMMAND", "command 类型需要 command 和 workingDirectory。")
            }
            options = try CommandOptions(workingDirectory: directory, timeoutSeconds: action.timeoutSeconds ?? 300,
                                         environment: action.environment ?? [:]).validated(command: command)
            kind = .command; target = command
        case "open", "folder", "file":
            guard action.url == nil, action.bundleIdentifier == nil, let path = action.path, !path.isEmpty else {
                throw TapDoneError("INVALID_PATH", "open/folder/file 需提供 path，不可同时提供 url 或 bundleIdentifier。")
            }
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw TapDoneError("INVALID_PATH", "path 需为绝对路径或 ~/ 开头的路径。") }
            let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &directory) else {
                throw TapDoneError("PATH_NOT_FOUND", "目标不存在：\(normalized)")
            }
            if action.type == "folder" && !directory.boolValue {
                throw TapDoneError("INVALID_PATH", "folder 目标必须是文件夹。")
            }
            kind = action.type == "folder" || (action.type == "open" && directory.boolValue) ? .folder : .file
            target = normalized
        default: throw TapDoneError("UNSUPPORTED_ACTION", "不支持任务类型：\(action.type)。当前支持 application、website、folder、file、open、command、external。")
        }
        let symbol = icon?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let symbol, (symbol.isEmpty || symbol.count > 100) {
            throw TapDoneError("INVALID_ICON", "图标需为有效的 SF Symbol 名称，长度为 1–100。")
        }
        let defaultSymbol = kind == .website ? "globe" : kind == .application ? "app" : kind == .folder ? "folder" : (kind == .command || kind == .external) ? "terminal" : "doc"
        guard presentation?.isValid ?? true else { throw TapDoneError("INVALID_PRESENTATION", "展示配置无效。") }
        return QuickAction(id: id, title: title, symbol: symbol ?? defaultSymbol, kind: kind, target: target, commandOptions: options, externalProgram: external, presentation: presentation)
    }
}

public struct ApplyResult: Codable {
    public init() {}
    public var created: [String] = []
    public var updated: [String] = []
}

public extension TaskLibrary {
    mutating func apply(_ documents: [TaskDocument]) throws -> ApplyResult {
        // Validate every document before modifying even an in-memory category.
        let resolved = try documents.map { try $0.validatedAction() }
        var result = ApplyResult()
        for (document, task) in zip(documents, resolved) {
            let categoryName = document.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = categories.indices.filter { categories[$0].name == categoryName }
            guard matches.count <= 1 else {
                throw TapDoneError("AMBIGUOUS_CATEGORY", "分类名重复：\(categoryName)。请先在设置中改为不同名称。")
            }
            let destination: Int
            if let match = matches.first { destination = match }
            else {
                categories.append(TaskCategory(id: UUID().uuidString, name: categoryName))
                destination = categories.count - 1
            }
            let existing = actions.first { $0.id == task.id }
            let position = categories[destination].tasks.firstIndex { $0.id == task.id }
            for index in categories.indices { categories[index].tasks.removeAll { $0.id == task.id } }
            var replacement = task
            if let existing {
                replacement.subtitle = existing.subtitle
                if document.presentation == nil { replacement.presentation = existing.presentation }
            }
            categories[destination].tasks.insert(replacement, at: position ?? categories[destination].tasks.count)
            // Omission preserves an existing pin; new tasks are unpinned.
            if let pinned = document.showInDock {
                if pinned {
                    if !dockTaskIDs.contains(task.id) { dockTaskIDs.append(task.id) }
                } else { dockTaskIDs.removeAll { $0 == task.id } }
            }
            if existing == nil { result.created.append(task.id) }
            else { result.updated.append(task.id) }
        }
        return result
    }
}
