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
            throw TapDoneError("INVALID_COMMAND", "命令不能为空、不能包含 NUL，且不能超过 128 KB。")
        }
        let expanded = (workingDirectory as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw TapDoneError("INVALID_WORKING_DIRECTORY", "工作目录必须是绝对路径或 ~/ 开头。")
        }
        var isDirectory: ObjCBool = false
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TapDoneError("INVALID_WORKING_DIRECTORY", "工作目录不存在：\(path)")
        }
        guard timeoutSeconds.isFinite, timeoutSeconds >= 1, timeoutSeconds <= 86400 else {
            throw TapDoneError("INVALID_TIMEOUT", "超时时间应为 1–86400 秒。")
        }
        for (key, value) in environment {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  !value.contains("\0") else {
                throw TapDoneError("INVALID_ENVIRONMENT", "环境变量名无效或值包含 NUL：\(key)")
            }
        }
        return CommandOptions(workingDirectory: path, timeoutSeconds: timeoutSeconds, environment: environment)
    }
}

/// Display preferences are separate from executable configuration.
public struct TaskPresentation: Codable, Equatable {
    public var builtinIconID: String?
    public var iconAssetID: String?
    public var useSymbol: Bool?
    public var activityTitle: String?
    public var activityEnabled: Bool?
    public init(iconAssetID: String? = nil, activityTitle: String? = nil, activityEnabled: Bool? = nil, useSymbol: Bool? = nil, builtinIconID: String? = nil) {
        self.builtinIconID = builtinIconID
        self.useSymbol = useSymbol
        self.iconAssetID = iconAssetID; self.activityTitle = activityTitle; self.activityEnabled = activityEnabled
    }
    private enum CodingKeys: String, CodingKey { case builtinIconID, iconAssetID, useSymbol, activityTitle, activityEnabled }
    private struct Field: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: Field.self)
        let allowed = Set(["builtinIconID", "iconAssetID", "useSymbol", "activityTitle", "activityEnabled"])
        guard raw.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw TapDoneError("INVALID_PRESENTATION", "展示配置包含未知字段。")
        }
        for key in raw.allKeys where try raw.decodeNil(forKey: key) {
            throw TapDoneError("INVALID_PRESENTATION", "展示字段不接受 null，请省略可选字段。")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        builtinIconID = try values.decodeIfPresent(String.self, forKey: .builtinIconID)
        useSymbol = try values.decodeIfPresent(Bool.self, forKey: .useSymbol)
        iconAssetID = try values.decodeIfPresent(String.self, forKey: .iconAssetID)
        activityTitle = try values.decodeIfPresent(String.self, forKey: .activityTitle)
        activityEnabled = try values.decodeIfPresent(Bool.self, forKey: .activityEnabled)
        guard isValid else { throw TapDoneError("INVALID_PRESENTATION", "展示配置无效。") }
    }
    public var isValid: Bool {
        (builtinIconID.map { id in BuiltinTaskIcon.all.contains { $0.id == id } } ?? true)
        && (iconAssetID.map { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } } ?? true)
        && (activityTitle.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 } ?? true)
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
    public var presentation: TaskPresentation?
    public var externalProgram: ExternalProgram?

    public init(id: String, title: String, subtitle: String = "", symbol: String, kind: ActionKind, target: String, commandOptions: CommandOptions? = nil, externalProgram: ExternalProgram? = nil, presentation: TaskPresentation? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.symbol = symbol; self.kind = kind; self.target = target
        self.presentation = presentation
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
            && actions.allSatisfy { ($0.presentation?.isValid ?? true) && !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.target.isEmpty && ($0.kind != .command || $0.commandOptions != nil) && ($0.kind != .external || $0.externalProgram != nil) }
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
    public var asyncOptions: RemoteAsyncOptions?
    public var inputContract: PayloadContract?
    public var outputContract: PayloadContract?
    public var protocolVersion: Int?
    public var executable: String
    public var arguments: [String]
    public var input: JSONValue
    public var options: CommandOptions
    public init(executable: String, arguments: [String] = [], input: JSONValue = .object([:]), options: CommandOptions, protocolVersion: Int = 1, inputContract: PayloadContract? = nil, outputContract: PayloadContract? = nil, asyncOptions: RemoteAsyncOptions? = nil) {
        self.asyncOptions = asyncOptions
        self.inputContract = inputContract; self.outputContract = outputContract
        self.protocolVersion = protocolVersion
        self.executable = executable; self.arguments = arguments; self.input = input; self.options = options
    }
    public func validated() throws -> ExternalProgram {
        guard [1, 2].contains(protocolVersion ?? 1) else { throw TapDoneError("UNSUPPORTED_PROTOCOL", "外部扩展协议仅支持 1 或 2。") }
        if let asyncOptions {
            _ = try asyncOptions.validated()
            guard protocolVersion == 2 else { throw TapDoneError("ASYNC_REQUIRES_V2", "异步任务必须使用协议 v2。") }
        }
        let path = (executable as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\0"), FileManager.default.isExecutableFile(atPath: path) else {
            throw TapDoneError("INVALID_EXECUTABLE", "可执行程序不存在或无法执行，请使用绝对路径：\(path)")
        }
        guard arguments.count <= 4096, !arguments.contains(where: { $0.contains("\0") }) else {
            throw TapDoneError("INVALID_ARGUMENTS", "arguments 最多 4096 项，参数不可包含 NUL。")
        }
        let validatedOptions = try options.validated(command: "external")
        guard try JSONEncoder().encode(input).count <= 1024 * 1024 else {
            throw TapDoneError("INPUT_TOO_LARGE", "外部扩展的 JSON input 不可超过 1 MB。")
        }
        try inputContract?.validate(input, path: "$input")
        return ExternalProgram(executable: URL(fileURLWithPath: path).standardizedFileURL.path,
                               arguments: arguments, input: input, options: validatedOptions, protocolVersion: protocolVersion ?? 1, inputContract: inputContract, outputContract: outputContract, asyncOptions: asyncOptions)
    }
}

public struct ExternalRequest: Codable {
    public let protocolVersion: Int
    public let taskID: String
    public let runID: String
    public let input: JSONValue
    public init(taskID: String, runID: String, input: JSONValue, protocolVersion: Int = 1) {
        self.protocolVersion = protocolVersion; self.taskID = taskID; self.runID = runID; self.input = input
    }
}

public struct ExternalResponse: Codable {
    public let protocolVersion: Int
    public let ok: Bool
    public let message: String?
    public let data: JSONValue?

    private enum CodingKeys: String, CodingKey { case protocolVersion, ok, message, data }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        ok = try values.decode(Bool.self, forKey: .ok)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        data = values.contains(.data) ? try values.decode(JSONValue.self, forKey: .data) : nil
    }
}

/// App-owned catalog. IDs are stable interchange values, never file paths.
public struct BuiltinTaskIcon: Identifiable {
    public let id: String
    public let title: String
    public let category: String
    public var assetName: String { "lucide-" + id }
    public static let categories = ["常用", "开发", "文件", "网络", "工具", "效率"]
    public static let all: [BuiltinTaskIcon] = [
        .init(id: "zap", title: "闪电", category: "常用"),
        .init(id: "star", title: "收藏", category: "常用"),
        .init(id: "heart", title: "喜欢", category: "常用"),
        .init(id: "flag", title: "标记", category: "常用"),
        .init(id: "bookmark", title: "书签", category: "常用"),
        .init(id: "bell", title: "提醒", category: "常用"),
        .init(id: "clock", title: "时钟", category: "常用"),
        .init(id: "circle-check", title: "完成", category: "常用"),
        .init(id: "terminal", title: "终端", category: "开发"),
        .init(id: "code", title: "代码", category: "开发"),
        .init(id: "braces", title: "脚本", category: "开发"),
        .init(id: "bug", title: "调试", category: "开发"),
        .init(id: "hammer", title: "构建", category: "开发"),
        .init(id: "git-branch", title: "分支", category: "开发"),
        .init(id: "package", title: "打包", category: "开发"),
        .init(id: "workflow", title: "工作流", category: "开发"),
        .init(id: "folder", title: "文件夹", category: "文件"),
        .init(id: "folder-open", title: "打开文件夹", category: "文件"),
        .init(id: "file", title: "文件", category: "文件"),
        .init(id: "file-text", title: "文档", category: "文件"),
        .init(id: "archive", title: "归档", category: "文件"),
        .init(id: "clipboard", title: "剪贴板", category: "文件"),
        .init(id: "download", title: "下载", category: "文件"),
        .init(id: "upload", title: "上传", category: "文件"),
        .init(id: "globe", title: "网站", category: "网络"),
        .init(id: "link", title: "链接", category: "网络"),
        .init(id: "server", title: "服务器", category: "网络"),
        .init(id: "database", title: "数据库", category: "网络"),
        .init(id: "cloud", title: "云端", category: "网络"),
        .init(id: "wifi", title: "网络", category: "网络"),
        .init(id: "network", title: "连接", category: "网络"),
        .init(id: "send", title: "发送", category: "网络"),
        .init(id: "settings", title: "设置", category: "工具"),
        .init(id: "wrench", title: "工具", category: "工具"),
        .init(id: "search", title: "搜索", category: "工具"),
        .init(id: "monitor", title: "显示器", category: "工具"),
        .init(id: "camera", title: "截图", category: "工具"),
        .init(id: "image", title: "图片", category: "工具"),
        .init(id: "scissors", title: "裁剪", category: "工具"),
        .init(id: "lock", title: "锁定", category: "工具"),
        .init(id: "play", title: "执行", category: "效率"),
        .init(id: "pause", title: "暂停", category: "效率"),
        .init(id: "refresh-cw", title: "刷新", category: "效率"),
        .init(id: "calendar", title: "日历", category: "效率"),
        .init(id: "list-checks", title: "清单", category: "效率"),
        .init(id: "chart-column", title: "统计", category: "效率"),
        .init(id: "rocket", title: "启动", category: "效率"),
        .init(id: "coffee", title: "休息", category: "效率"),
    ]
}
