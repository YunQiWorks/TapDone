import Foundation
import Darwin
#if SWIFT_PACKAGE
import TapDoneCore
#endif

// JSON is the only stdout format, including errors. No command executes a task.
private func emit(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private struct Arguments {
    var values: [String]
    mutating func take(_ flag: String) throws -> String? {
        let positions = values.indices.filter { values[$0] == flag }
        guard positions.count <= 1 else { throw TapDoneError("INVALID_ARGUMENT", "重复参数：\(flag)") }
        guard let index = positions.first else { return nil }
        guard index + 1 < values.count else { throw TapDoneError("INVALID_ARGUMENT", "缺少参数值：\(flag)") }
        let value = values[index + 1]
        values.removeSubrange(index...index + 1)
        return value
    }
    mutating func word() throws -> String {
        guard !values.isEmpty else { throw TapDoneError("INVALID_ARGUMENT", "缺少命令参数，请使用 tapdone help。") }
        return values.removeFirst()
    }
    func finish() throws {
        guard values.isEmpty else { throw TapDoneError("INVALID_ARGUMENT", "未知参数：\(values.joined(separator: " "))") }
    }
}

private func taskJSON(_ task: QuickAction, category: TaskCategory, library: TaskLibrary) -> [String: Any] {
    var action: [String: Any]
    switch task.kind {
    case .application: action = ["type": "application", "bundleIdentifier": task.target]
    case .website: action = ["type": "website", "url": task.target]
    case .external:
        let program = task.externalProgram
        let inputData = try? JSONEncoder().encode(program?.input ?? .object([:]))
        let payload = inputData.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } ?? NSNull()
        action = ["protocolVersion": program?.protocolVersion ?? 1, "type": "external", "executable": program?.executable ?? task.target, "arguments": program?.arguments ?? [],
                  "input": payload, "workingDirectory": program?.options.workingDirectory ?? "",
                  "timeoutSeconds": program?.options.timeoutSeconds ?? 300, "environment": program?.options.environment ?? [:]]
        if let options = program?.asyncOptions, let data = try? JSONEncoder().encode(options),
           let value = try? JSONSerialization.jsonObject(with: data) { action["asyncOptions"] = value }
        for (key, contract) in [("inputContract", program?.inputContract), ("outputContract", program?.outputContract)] {
            if let contract, let data = try? JSONEncoder().encode(contract),
               let value = try? JSONSerialization.jsonObject(with: data) { action[key] = value }
        }
    case .command:
        let options = task.commandOptions
        action = ["type": "command", "command": task.target, "workingDirectory": options?.workingDirectory ?? "",
                  "timeoutSeconds": options?.timeoutSeconds ?? 300, "environment": options?.environment ?? [:]]
    case .folder, .file:
        let expanded = (task.target as NSString).expandingTildeInPath
        let path = expanded.hasPrefix("/") ? expanded : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(expanded).path
        action = ["type": task.kind.rawValue, "path": path]
    }
    var document: [String: Any] = ["schemaVersion": 1, "id": task.id, "category": category.name, "name": task.title,
            "icon": task.symbol, "showInDock": library.dockTaskIDs.contains(task.id), "action": action]
    if let presentation = task.presentation {
        document["presentation"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(presentation))
    }
    return document
}

private func input(_ path: String) throws -> [TaskDocument] {
    let data: Data
    do {
        data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    } catch { throw TapDoneError("INPUT_UNREADABLE", "无法读取输入文件：\(error.localizedDescription)") }
    guard data.count <= 16 * 1024 * 1024 else { throw TapDoneError("INPUT_TOO_LARGE", "输入文件不能超过 16 MB。") }
    return try TaskDocument.decode(data)
}

private func revision(_ text: String?) throws -> UInt64? {
    guard let text else { return nil }
    guard let value = UInt64(text) else { throw TapDoneError("INVALID_ARGUMENT", "--if-revision 必须为非负整数。") }
    return value
}

private func run() throws {
    var args = Arguments(values: Array(CommandLine.arguments.dropFirst()))
    let directory = try args.take("--library-dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    let command = args.values.isEmpty ? "help" : try args.word()
    if command == "help" || command == "--help" || command == "-h" {
        try args.finish()
        try emit(["ok": true, "commands": ["paths", "schema", "workflow validate --file <path|->", "categories list", "tasks list", "tasks validate --file <path|->", "tasks apply --file <path|-> [--if-revision <revision>]", "tasks update <id> --dock <true|false> [--if-revision <revision>]"],
                  "options": ["--library-dir <directory>: 使用独立配置目录"],
                  "note": "添加或更新任务不会执行任务。validate 仅检查和预览；apply 批量全成或全败。"])
        return
    }
    if command == "schema" {
        try args.finish()
        let data = Data(taskSchema.utf8)
        try emit(try JSONSerialization.jsonObject(with: data))
        return
    }
    let repository = TaskRepository(directoryURL: directory)
    if command == "paths" {
        try args.finish()
        try emit(["ok": true, "library": repository.libraryURL.path, "scripts": repository.directoryURL.appendingPathComponent("scripts").path])
        return
    }
    let subcommand = try args.word()
    if command == "workflow" && subcommand == "validate" {
        guard let file = try args.take("--file") else { throw TapDoneError("INVALID_ARGUMENT", "需要 --file <path|->。") }
        try args.finish()
        let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
        let definition = try WorkflowDefinition.decode(data)
        let plan = try definition.plan(library: repository.read())
        try emit(["ok": true, "executed": false, "workflowID": definition.id,
                  "libraryRevision": plan.libraryRevision, "orderedNodeIDs": plan.orderedNodeIDs,
                  "reviewNodes": definition.nodes.filter { $0.kind == .review }.map(\.id),
                  "note": "仅校验流程和任务快照，不保存或执行。"])
    } else if command == "categories" && subcommand == "list" {
        try args.finish()
        let library = try repository.read()
        try emit(["ok": true, "revision": library.revision, "categories": library.categories.map {
            ["id": $0.id, "name": $0.name, "taskCount": $0.tasks.count] as [String: Any]
        }])
    } else if command == "tasks" && subcommand == "list" {
        try args.finish()
        let library = try repository.read()
        let tasks = library.categories.flatMap { category in category.tasks.map { taskJSON($0, category: category, library: library) } }
        try emit(["ok": true, "revision": library.revision, "tasks": tasks])
    } else if command == "tasks" && (subcommand == "validate" || subcommand == "apply") {
        guard let file = try args.take("--file") else { throw TapDoneError("INVALID_ARGUMENT", "需要 --file <path>，或 --file - 从 stdin 读取。") }
        let expected = try revision(args.take("--if-revision"))
        try args.finish()
        let documents = try input(file)
        let result: ApplyResult
        let library: TaskLibrary
        if subcommand == "validate" {
            var preview = try repository.read()
            if let expected, expected != preview.revision { throw TapDoneError("REVISION_CONFLICT", "任务库已变化，请重新读取。") }
            result = try preview.apply(documents)
            library = preview
        } else {
            var outcome = ApplyResult()
            library = try repository.transaction(expectedRevision: expected) { latest in outcome = try latest.apply(documents) }
            result = outcome
        }
        try emit(["ok": true, "applied": subcommand == "apply", "revision": library.revision,
                  "created": result.created, "updated": result.updated, "library": repository.libraryURL.path])
    } else if command == "tasks" && subcommand == "update" {
        let id = try args.word()
        guard let value = try args.take("--dock"), ["true", "false"].contains(value) else {
            throw TapDoneError("INVALID_ARGUMENT", "update 需要 --dock true 或 --dock false。")
        }
        let expected = try revision(args.take("--if-revision"))
        try args.finish()
        let library = try repository.transaction(expectedRevision: expected) { latest in
            guard latest.actions.contains(where: { $0.id == id }) else { throw TapDoneError("TASK_NOT_FOUND", "任务不存在：\(id)") }
            if value == "true" {
                if !latest.dockTaskIDs.contains(id) { latest.dockTaskIDs.append(id) }
            } else { latest.dockTaskIDs.removeAll { $0 == id } }
        }
        try emit(["ok": true, "id": id, "showInDock": value == "true", "revision": library.revision])
    } else {
        throw TapDoneError("UNKNOWN_COMMAND", "未知命令：\(command) \(subcommand)。请使用 tapdone help。")
    }
}

private let taskSchema = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "TapDone task or batch",
  "oneOf": [
    {
      "$ref": "#/$defs/task"
    },
    {
      "type": "array",
      "minItems": 1,
      "items": {
        "$ref": "#/$defs/task"
      }
    }
  ],
  "$defs": {
    "task": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "schemaVersion",
        "id",
        "category",
        "name",
        "action"
      ],
      "properties": {
        "schemaVersion": {
          "const": 1
        },
        "id": {
          "type": "string",
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
        },
        "category": {
          "type": "string",
          "minLength": 1,
          "maxLength": 80
        },
        "name": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120
        },
        "icon": {
          "type": "string",
          "minLength": 1,
          "maxLength": 100
        },
        "showInDock": {
          "type": "boolean"
        },
        "action": {
          "oneOf": [
            {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "type",
                "bundleIdentifier"
              ],
              "properties": {
                "type": {
                  "const": "application"
                },
                "bundleIdentifier": {
                  "type": "string",
                  "pattern": "^[A-Za-z0-9][A-Za-z0-9.-]+$"
                }
              }
            },
            {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "type",
                "url"
              ],
              "properties": {
                "type": {
                  "const": "website"
                },
                "url": {
                  "type": "string",
                  "pattern": "^[Hh][Tt][Tt][Pp][Ss]?://",
                  "format": "uri"
                }
              }
            },
            {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "type",
                "path"
              ],
              "properties": {
                "type": {
                  "enum": [
                    "open",
                    "folder",
                    "file"
                  ]
                },
                "path": {
                  "type": "string",
                  "minLength": 1
                }
              }
            },
            {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "type",
                "command",
                "workingDirectory"
              ],
              "properties": {
                "type": {
                  "const": "command"
                },
                "command": {
                  "type": "string",
                  "minLength": 1
                },
                "workingDirectory": {
                  "type": "string",
                  "minLength": 1
                },
                "timeoutSeconds": {
                  "type": "number",
                  "minimum": 1,
                  "maximum": 86400,
                  "default": 300
                },
                "environment": {
                  "type": "object",
                  "propertyNames": {
                    "pattern": "^[A-Za-z_][A-Za-z0-9_]*$"
                  },
                  "additionalProperties": {
                    "type": "string"
                  }
                }
              }
            },
            {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "type",
                "executable",
                "workingDirectory"
              ],
              "properties": {
                "type": {
                  "const": "external"
                },
                "executable": {
                  "type": "string",
                  "minLength": 1
                },
                "arguments": {
                  "type": "array",
                  "maxItems": 4096,
                  "items": {
                    "type": "string"
                  }
                },
                "input": {},
                "workingDirectory": {
                  "type": "string",
                  "minLength": 1
                },
                "timeoutSeconds": {
                  "type": "number",
                  "minimum": 1,
                  "maximum": 86400,
                  "default": 300
                },
                "environment": {
                  "type": "object",
                  "propertyNames": {
                    "pattern": "^[A-Za-z_][A-Za-z0-9_]*$"
                  },
                  "additionalProperties": {
                    "type": "string"
                  }
                },
                "protocolVersion": {
                  "type": "integer",
                  "enum": [
                    1,
                    2
                  ],
                  "default": 1
                },
                "inputContract": {
                  "$ref": "#/$defs/payloadContract"
                },
                "outputContract": {
                  "$ref": "#/$defs/payloadContract"
                },
                "asyncOptions": {
                  "type": "object",
                  "additionalProperties": false,
                  "properties": {
                    "pollIntervalSeconds": {
                      "type": "number",
                      "minimum": 2,
                      "maximum": 300,
                      "default": 5
                    },
                    "timeoutSeconds": {
                      "type": "number",
                      "minimum": 1,
                      "maximum": 86400,
                      "default": 3600
                    }
                  }
                }
              },
              "allOf": [
                {
                  "if": {
                    "required": [
                      "asyncOptions"
                    ]
                  },
                  "then": {
                    "required": [
                      "protocolVersion"
                    ],
                    "properties": {
                      "protocolVersion": {
                        "const": 2
                      }
                    }
                  }
                }
              ]
            }
          ]
        },
        "presentation": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "iconAssetID": {
              "type": "string",
              "pattern": "^[0-9a-f]{64}$"
            },
            "activityTitle": {
              "type": "string",
              "minLength": 1,
              "maxLength": 200,
              "pattern": "\\S"
            },
            "activityEnabled": {
              "type": "boolean"
            },
            "useSymbol": {
              "type": "boolean",
              "description": "Prefer the configured SF Symbol over the native application/file icon. Imported image takes precedence."
            },
            "builtinIconID": {
              "type": "string",
              "enum": [
                "zap",
                "star",
                "heart",
                "flag",
                "bookmark",
                "bell",
                "clock",
                "circle-check",
                "terminal",
                "code",
                "braces",
                "bug",
                "hammer",
                "git-branch",
                "package",
                "workflow",
                "folder",
                "folder-open",
                "file",
                "file-text",
                "archive",
                "clipboard",
                "download",
                "upload",
                "globe",
                "link",
                "server",
                "database",
                "cloud",
                "wifi",
                "network",
                "send",
                "settings",
                "wrench",
                "search",
                "monitor",
                "camera",
                "image",
                "scissors",
                "lock",
                "play",
                "pause",
                "refresh-cw",
                "calendar",
                "list-checks",
                "chart-column",
                "rocket",
                "coffee"
              ]
            }
          }
        }
      }
    },
    "payloadContract": {
      "description": "TapDone bounded contract subset; depth <=12 and encoded size <=64 KB are enforced by runtime.",
      "oneOf": [
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "const": "object"
            },
            "properties": {
              "type": "object",
              "maxProperties": 128,
              "propertyNames": {
                "minLength": 1,
                "maxLength": 256
              },
              "additionalProperties": {
                "$ref": "#/$defs/payloadContract"
              }
            },
            "required": {
              "type": "array",
              "uniqueItems": true,
              "items": {
                "type": "string"
              }
            },
            "additionalProperties": {
              "type": "boolean"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type",
            "items"
          ],
          "properties": {
            "type": {
              "const": "array"
            },
            "items": {
              "$ref": "#/$defs/payloadContract"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "const": "string"
            },
            "minLength": {
              "type": "integer",
              "minimum": 0,
              "maximum": 1048576
            },
            "maxLength": {
              "type": "integer",
              "minimum": 0,
              "maximum": 1048576
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "const": "number"
            },
            "minimum": {
              "type": "number"
            },
            "maximum": {
              "type": "number"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "const": "integer"
            },
            "minimum": {
              "type": "number"
            },
            "maximum": {
              "type": "number"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "const": "boolean"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "const": "null"
            }
          }
        }
      ]
    }
  }
}
"""#

do { try run() }
catch {
    let failure = error as? TapDoneError
    try? emit(["ok": false, "error": ["code": failure?.code ?? "UNEXPECTED_ERROR", "message": error.localizedDescription]])
    exit(1)
}
