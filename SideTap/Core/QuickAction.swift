import Foundation

public enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case application, website, folder, file, command, external
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .application: return "应用"
        case .website: return "网址"
        case .folder: return "文件夹"
        case .file: return "文件"
        case .command: return "命令 / 脚本"
        case .external: return "外部扩展（通用接口）"
        }
    }
}

public struct CommandOptions: Codable, Equatable {
    public var workingDirectory: String
    public var timeoutSeconds: Double
    public var environment: [String: String]
    public init(workingDirectory: String, timeoutSeconds: Double = 300, environment: [String: String] = [:]) {
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
    }

    public func validated(command: String) throws -> CommandOptions {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 131072, !command.contains("\0") else {
            throw SideTapError("INVALID_COMMAND", "命令不能为空、不能包含 NUL，且不能超过 128 KB。")
        }
        let expanded = (workingDirectory as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw SideTapError("INVALID_WORKING_DIRECTORY", "工作目录必须是绝对路径或 ~/ 开头。")
        }
        var isDirectory: ObjCBool = false
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SideTapError("INVALID_WORKING_DIRECTORY", "工作目录不存在：\(path)")
        }
        guard timeoutSeconds.isFinite, timeoutSeconds >= 1, timeoutSeconds <= 86400 else {
            throw SideTapError("INVALID_TIMEOUT", "超时时间应为 1–86400 秒。")
        }
        for (key, value) in environment {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  !value.contains("\0") else {
                throw SideTapError("INVALID_ENVIRONMENT", "环境变量名无效或值包含 NUL：\(key)")
            }
        }
        return CommandOptions(workingDirectory: path, timeoutSeconds: timeoutSeconds, environment: environment)
    }
}

public struct QuickAction: Identifiable, Codable, Equatable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var kind: ActionKind
    public var target: String
    public var commandOptions: CommandOptions?
    public var externalProgram: ExternalProgram?

    public init(id: String, title: String, subtitle: String = "", symbol: String, kind: ActionKind, target: String, commandOptions: CommandOptions? = nil, externalProgram: ExternalProgram? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.symbol = symbol; self.kind = kind; self.target = target
        self.commandOptions = commandOptions
        self.externalProgram = externalProgram
    }

    public static let examples: [QuickAction] = [
        .init(id: "finder", title: "访达", subtitle: "浏览文件", symbol: "folder", kind: .application, target: "com.apple.finder"),
        .init(id: "safari", title: "Safari", subtitle: "打开浏览器", symbol: "safari", kind: .application, target: "com.apple.Safari"),
        .init(id: "terminal", title: "终端", subtitle: "开始命令行工作", symbol: "terminal", kind: .application, target: "com.apple.Terminal"),
        .init(id: "downloads", title: "下载", subtitle: "打开下载文件夹", symbol: "arrow.down.circle", kind: .folder, target: "Downloads"),
        .init(id: "github", title: "GitHub", subtitle: "发现开源项目", symbol: "globe", kind: .website, target: "https://github.com")
    ]
}

public struct TaskCategory: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var tasks: [QuickAction]
    public init(id: String, name: String, tasks: [QuickAction] = []) {
        self.id = id; self.name = name; self.tasks = tasks
    }
}

public struct TaskLibrary: Codable, Equatable {
    public var formatVersion: Int
    public var revision: UInt64
    public var categories: [TaskCategory]
    public var dockTaskIDs: [String]

    public init(categories: [TaskCategory] = [], dockTaskIDs: [String] = [], revision: UInt64 = 0) {
        formatVersion = 1; self.revision = revision
        self.categories = categories; self.dockTaskIDs = dockTaskIDs
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, revision, categories, dockTaskIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        categories = try values.decode([TaskCategory].self, forKey: .categories)
        dockTaskIDs = try values.decode([String].self, forKey: .dockTaskIDs)
    }

    public var actions: [QuickAction] { categories.flatMap(\.tasks) }
    public var isValid: Bool {
        let categoryIDs = categories.map(\.id)
        let taskIDs = actions.map(\.id)
        return formatVersion == 1 && Set(categoryIDs).count == categoryIDs.count
            && Set(taskIDs).count == taskIDs.count
            && Set(dockTaskIDs).count == dockTaskIDs.count
            && Set(dockTaskIDs).isSubset(of: Set(taskIDs))
            && categories.allSatisfy { !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && actions.allSatisfy { !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.target.isEmpty && ($0.kind != .command || $0.commandOptions != nil) && ($0.kind != .external || $0.externalProgram != nil) }
    }
}

/// Extensible payloads stay in JSON rather than adding a Swift type for every capability.
public enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .number(try value.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

public struct ExternalProgram: Codable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var input: JSONValue
    public var options: CommandOptions
    public init(executable: String, arguments: [String] = [], input: JSONValue = .object([:]), options: CommandOptions) {
        self.executable = executable; self.arguments = arguments; self.input = input; self.options = options
    }
    public func validated() throws -> ExternalProgram {
        let path = (executable as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\0"), FileManager.default.isExecutableFile(atPath: path) else {
            throw SideTapError("INVALID_EXECUTABLE", "可执行程序不存在或无法执行，请使用绝对路径：\(path)")
        }
        guard arguments.count <= 4096, !arguments.contains(where: { $0.contains("\0") }) else {
            throw SideTapError("INVALID_ARGUMENTS", "arguments 最多 4096 项，参数不可包含 NUL。")
        }
        let validatedOptions = try options.validated(command: "external")
        guard try JSONEncoder().encode(input).count <= 1024 * 1024 else {
            throw SideTapError("INPUT_TOO_LARGE", "外部扩展的 JSON input 不可超过 1 MB。")
        }
        return ExternalProgram(executable: URL(fileURLWithPath: path).standardizedFileURL.path,
                               arguments: arguments, input: input, options: validatedOptions)
    }
}

public struct ExternalRequest: Codable {
    public let protocolVersion: Int
    public let taskID: String
    public let runID: String
    public let input: JSONValue
    public init(taskID: String, runID: String, input: JSONValue) {
        protocolVersion = 1; self.taskID = taskID; self.runID = runID; self.input = input
    }
}

public struct ExternalResponse: Codable {
    public let protocolVersion: Int
    public let ok: Bool
    public let message: String?
    public let data: JSONValue?
}
